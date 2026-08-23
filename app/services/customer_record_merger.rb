class CustomerRecordMerger
  CONFIGURATION = {
    Account => { merge_class: AccountMerge, association: :accounts, action: "account" },
    Contact => { merge_class: ContactMerge, association: :contacts, action: "contact" }
  }.freeze

  def self.merge!(workspace:, source:, target:, membership:)
    configuration = CONFIGURATION.fetch(source.class)
    raise ArgumentError, "records must have the same type" unless source.class == target.class

    configuration.fetch(:merge_class).transaction do
      lock_graph(workspace, source.class)
      reviewer = authorized_membership!(workspace, membership)
      relation = workspace.public_send(configuration.fetch(:association))
      source_record = relation.lock.find(source.id)
      target_record = relation.lock.find(target.id).canonical
      target_record.lock!
      raise ArgumentError, "source record is already merged" unless source_record.canonical == source_record
      raise ArgumentError, "cannot merge a record into itself" if source_record == target_record
      ensure_contact_accounts_match!(source_record, target_record)

      merge = configuration.fetch(:merge_class).create!(
        workspace: workspace,
        source: source_record,
        target: target_record,
        merged_by: reviewer.user,
        merged_at: Time.current
      )
      audit!("#{configuration.fetch(:action)}.merged", merge, reviewer.user)
      target_record
    end
  end

  def self.unmerge!(workspace:, source:, membership:)
    configuration = CONFIGURATION.fetch(source.class)

    configuration.fetch(:merge_class).transaction do
      lock_graph(workspace, source.class)
      reviewer = authorized_membership!(workspace, membership)
      source_record = workspace.public_send(configuration.fetch(:association)).find(source.id)
      merge = configuration.fetch(:merge_class).active.lock.find_by!(workspace: workspace, source: source_record)
      merge.update!(unmerged_by: reviewer.user, unmerged_at: Time.current)
      audit!("#{configuration.fetch(:action)}.unmerged", merge, reviewer.user)
      source_record
    end
  end

  def self.authorized_membership!(workspace, membership)
    workspace.memberships.lock.find(membership.id).tap do |current_membership|
      raise Current::RoleAccessDenied unless current_membership.can_manage_work?
    end
  end
  private_class_method :authorized_membership!

  def self.ensure_contact_accounts_match!(source, target)
    return unless source.is_a?(Contact)
    return if source.account&.canonical == target.account&.canonical

    raise ArgumentError, "contacts belong to different accounts"
  end
  private_class_method :ensure_contact_accounts_match!

  def self.lock_graph(workspace, record_class)
    value = SourceIdentity.connection.quote("customer-merge:#{workspace.id}:#{record_class.name}")
    SourceIdentity.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{value}))")
  end
  private_class_method :lock_graph

  def self.audit!(action, merge, actor)
    AuditEvent.record!(action: action, source: :web, workspace: merge.workspace, actor: actor, subject: merge)
  end
  private_class_method :audit!
end
