class SupportCasesController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_support_case, except: :index
  rescue_from ActiveRecord::ActiveRecordError, with: :case_load_failure

  def index
    @workspace = Current.require_workspace!
    @membership = Current.require_membership!
    load_queue
  end

  def show
    load_workspace
  end

  private
    def set_support_case
      @support_case = Current.require_workspace!.support_cases
        .includes(conversation: { contact: :account })
        .find(params[:id])
    end

    def load_workspace
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      load_queue(limit: 25)
      @messages = @support_case.conversation.conversation_messages
      @status_changes = @support_case.status_changes.includes(:actor).order(occurred_at: :desc, id: :desc)
      @notes = @support_case.case_notes.includes(:author).order(created_at: :desc, id: :desc)
      @available_tags = @workspace.tags.where.not(id: @support_case.tag_ids).order(:name)
      @assignable_memberships = @workspace.memberships.where.not(role: :viewer).includes(:user).order("users.email_address")
      @activity_items = case_activity
      contact = @support_case.conversation.contact.canonical
      account = contact.account&.canonical
      @contact_emails = identity_values(contact, :email)
      @account_domains = account ? identity_values(account, :domain) : []
      @email_thread = @workspace.email_threads.includes(:shared_email_inbox).find_by(conversation_id: @support_case.conversation_id)
      @email_recipient = HumanEmailSend.recipient_preview(workspace: @workspace, support_case: @support_case) if @email_thread
      @email_draft = @support_case.email_draft || @workspace.email_drafts.new(
        support_case: @support_case, email_thread: @email_thread, conversation: @support_case.conversation
      )
      @email_delivery = @email_draft.persisted? ? @email_draft.outbound_email_deliveries.order(created_at: :desc).first : nil
      @email_follow_up_available = EmailDraftWorkflow.follow_up_available?(@email_draft)
      @send_token ||= SecureRandom.uuid
    end

    def queue_scope
      scope = Current.workspace.support_cases
        .left_joins(:conversation)
        .includes(:tags, assigned_membership: :user, conversation: { contact: :account })
      scope = case params[:status].presence || "open"
      when "open" then scope.where.not(status: :closed)
      when "all" then scope
      when *SupportCase::STATUSES then scope.where(status: params[:status])
      else scope.where.not(status: :closed)
      end
      scope = scope.where(priority: params[:priority]) if SupportCase::PRIORITIES.include?(params[:priority])
      scope = scope.where(assigned_membership: @membership) if params[:assignment] == "mine"
      scope = scope.where(assigned_membership: nil) if params[:assignment] == "unassigned"
      scope = scope.joins(:support_case_taggings).where(support_case_taggings: { tag_id: Current.workspace.tags.select(:id).where(id: params[:tag_id]) }) if params[:tag_id].present?
      scope.order(Arel.sql("COALESCE(conversations.last_message_at, conversations.started_at) DESC"), id: :desc)
    end

    def load_queue(limit: 50)
      @page = [ params[:page].to_i, 1 ].max
      records = queue_scope.offset((@page - 1) * limit).limit(limit + 1).to_a
      @has_next_page = records.length > limit
      @support_cases = records.first(limit)
      @latest_messages_by_conversation_id = latest_messages_by_conversation_id
      @queue_filters_active = %i[status priority assignment tag_id].any? { |key| params[key].present? && params[key] != "open" }
    end

    def latest_messages_by_conversation_id
      conversation_ids = @support_cases.map(&:conversation_id)
      return {} if conversation_ids.empty?

      @workspace.conversation_messages
        .where(conversation_id: conversation_ids)
        .select("DISTINCT ON (conversation_id) conversation_messages.*")
        .order(conversation_id: :desc, occurred_at: :desc, id: :desc)
        .index_by(&:conversation_id)
    end

    def case_activity
      audit_events = @workspace.audit_events.where(
        subject_type: "SupportCase",
        subject_id: @support_case.id,
        action: %w[case.assigned case.unassigned case.priority_changed case.tag_added case.tag_removed]
      )
      (@status_changes.to_a + @notes.to_a + audit_events.to_a)
        .sort_by { |item| item.respond_to?(:occurred_at) ? item.occurred_at : item.created_at }
        .reverse
        .first(50)
    end

    def case_load_failure(error)
      raise error if error.is_a?(ActiveRecord::RecordNotFound)

      Rails.logger.error("Case workspace load failed: #{error.class}")
      render "shared/error_state", status: :service_unavailable
    end

    def identity_values(record, kind)
      record.source_identities.matched
        .joins(:source_identity_keys)
        .merge(SourceIdentityKey.current.where(kind: kind))
        .pluck("source_identity_keys.normalized_value")
        .uniq
        .sort
    end
end
