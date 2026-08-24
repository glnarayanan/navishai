class AuditEvent < ApplicationRecord
  ACTOR_KINDS = %w[user break_glass system anonymous].freeze
  SOURCES = %w[web job task runner integration system].freeze
  SENSITIVE_KEY = /passw|email|secret|token|(?:\A|_)key(?:\z|_)|crypt|salt|certificate|otp|ssn|cvv|cvc/i
  MAX_METADATA_BYTES = 8.kilobytes
  EVENT_METADATA = {
    "authentication.failed" => { "method" => %w[local break_glass] },
    "authentication.signed_out" => {},
    "authentication.succeeded" => { "method" => %w[local break_glass] },
    "account.created" => {},
    "account.data_imported" => { "source_kind" => AccountHealthInput::SOURCE_KINDS, "record_count" => Integer },
    "account.health_recalculated" => {
      "trigger_kind" => AccountHealthAssessment::TRIGGER_KINDS,
      "risk_level" => AccountHealthAssessment::RISK_LEVELS
    },
    "account.merged" => {},
    "account.risk_detected" => { "trigger_kind" => AccountRiskInvestigation::TRIGGER_KINDS },
    "account.risk_resolved" => {},
    "account.risk_started" => {},
    "account.unmerged" => {},
    "agent.profile_updated" => {},
    "crew.artifact_published" => { "artifact_kind" => CrewArtifact::KINDS, "version" => Integer },
    "crew.task_created" => {},
    "crew.task_event_recorded" => { "event_kind" => CrewTaskEvent::KINDS },
    "execution.run_reconciled" => {},
    "execution.run_requested" => {},
    "attachment.downloaded" => {},
    "attachment.removed" => { "attachment_id" => Integer },
    "attachment.uploaded" => { "scan_status" => StoredAttachment::SCAN_STATUSES },
    "break_glass.configured" => {},
    "contact.created" => {},
    "contact.merged" => {},
    "contact.unmerged" => {},
    "conversation.created" => {},
    "conversation.message_added" => { "direction" => %w[inbound outbound], "author_kind" => %w[contact user external] },
    "case.assigned" => { "assignee_id" => Integer },
    "case.created" => {},
    "case.note_added" => {},
    "case.priority_changed" => { "from_priority" => %w[low normal high urgent], "to_priority" => %w[low normal high urgent] },
    "case.status_changed" => {
      "from_status" => %w[new triaged investigating waiting_customer waiting_internal draft_ready awaiting_human_review resolved closed],
      "to_status" => %w[new triaged investigating waiting_customer waiting_internal draft_ready awaiting_human_review resolved closed]
    },
    "case.tag_added" => { "tag_id" => Integer },
    "case.tag_removed" => { "tag_id" => Integer },
    "case.unassigned" => {},
    "case.sla_started" => { "policy_id" => Integer },
    "email_verification.completed" => {},
    "email.intake_failed" => { "failure_code" => InboundEmailDelivery::FAILURE_CODES },
    "email.intake_received" => {},
    "email.intake_retried" => { "failure_code" => InboundEmailDelivery::FAILURE_CODES },
    "email.draft_saved" => {},
    "email.inbox_created" => {},
    "email.inbox_updated" => { "active" => %w[true false] },
    "email.send_failed" => { "failure_code" => OutboundEmailDelivery::FAILURE_CODES },
    "email.send_reviewed" => { "outcome" => %w[accepted rejected] },
    "email.send_started" => {},
    "email.send_succeeded" => {},
    "installation.bootstrapped" => {},
    "intercom.connection_created" => {},
    "intercom.connection_updated" => { "active" => %w[true false] },
    "intercom.conversation_synced" => {},
    "intercom.identity_retired" => { "entity_kind" => %w[account contact] },
    "intercom.sync_completed" => { "operation_kind" => IntercomSyncOperation::OPERATION_KINDS },
    "intercom.sync_enqueued" => { "operation_kind" => IntercomSyncOperation::OPERATION_KINDS },
    "intercom.sync_failed" => {
      "operation_kind" => IntercomSyncOperation::OPERATION_KINDS,
      "failure_code" => %w[configuration_error remote_rejected outcome_unknown]
    },
    "intercom.draft_saved" => {},
    "intercom.send_failed" => { "failure_code" => IntercomOutboundDelivery::FAILURE_CODES },
    "intercom.send_reviewed" => { "outcome" => %w[accepted rejected] },
    "intercom.send_started" => {},
    "intercom.send_succeeded" => {},
    "intercom.webhook_failed" => { "failure_code" => IntercomWebhookDelivery::FAILURE_CODES },
    "intercom.webhook_processed" => {},
    "intercom.webhook_retried" => { "failure_code" => IntercomWebhookDelivery::FAILURE_CODES },
    "knowledge.source_created" => {},
    "knowledge.source_deleted" => {},
    "knowledge.version_created" => {},
    "memory.procedure_published" => {},
    "memory.proposal_created" => { "memory_type" => MemoryProposal::MEMORY_TYPES },
    "memory.proposal_reviewed" => { "outcome" => %w[accepted rejected] },
    "memory.record_captured" => { "memory_type" => MemoryRecord::MEMORY_TYPES },
    "memory.record_inspected" => {},
    "memory.library_inspected" => { "access_scope" => %w[all used], "record_count" => Integer },
    "memory.correction_proposed" => {},
    "memory.correction_reviewed" => { "outcome" => %w[accepted rejected] },
    "memory.record_deleted" => {},
    "memory.index_removal_retried" => {},
    "memory.exported" => { "record_count" => Integer },
    "memory.imported" => { "record_count" => Integer },
    "memory.index_reconstructed" => { "queued_count" => Integer },
    "runtime.installation_approved" => {},
    "runtime.installation_revoked" => {},
    "runtime.installations_checked" => { "detected_count" => Integer },
    "scorecard.backtested" => { "version" => Integer, "sample_count" => Integer },
    "scorecard.proposed" => { "version" => Integer },
    "scorecard.published" => { "from_version" => Integer, "to_version" => Integer },
    "scorecard.rolled_back" => { "from_version" => Integer, "to_version" => Integer },
    "password_reset.completed" => {},
    "password_reset.requested" => {},
    "public_web.search_completed" => { "provider" => String, "result_count" => Integer, "cost_units" => Integer },
    "public_web.search_failed" => { "failure_code" => String },
    "public_web.search_requested" => { "policy_decision" => %w[allowed redacted] },
    "public_web.search_retried" => {},
    "public_web.extraction_completed" => {},
    "public_web.extraction_failed" => { "failure_code" => String },
    "public_web.extraction_requested" => {},
    "public_web.extraction_retried" => {},
    "source_identity.ambiguous" => { "entity_kind" => %w[account contact], "candidate_count" => Integer },
    "source_identity.matched" => { "entity_kind" => %w[account contact], "resolution_method" => %w[created deterministic] },
    "source_identity.reviewed" => { "entity_kind" => %w[account contact], "resolution_method" => %w[reviewed] },
    "sla.escalation_created" => { "objective" => %w[first_response resolution], "kind" => %w[warning breach] },
    "sla.escalation_reactivated" => { "objective" => %w[first_response resolution], "kind" => %w[warning breach] },
    "tag.created" => {},
    "workspace_invitation.accepted" => { "role" => Membership::ROLES },
    "workspace_invitation.created" => { "role" => Membership::ROLES },
    "workspace_invitation.revoked" => { "role" => Membership::ROLES },
    "workspace.data_policy_updated" => {
      "content_retention_days" => Integer,
      "audit_retention_days" => Integer
    }
  }.freeze

  belongs_to :workspace, optional: true
  belongs_to :actor, class_name: "User", optional: true
  has_many :notifications, foreign_key: :source_audit_event_id, dependent: :restrict_with_exception

  after_create_commit -> { NotificationFanoutJob.enqueue_after_commit(self) },
    if: -> { workspace_id && NotificationFanout.notifiable_action?(action) }

  enum :actor_kind, ACTOR_KINDS.index_by(&:itself), validate: true
  enum :source, SOURCES.index_by(&:itself), prefix: true, validate: true

  validates :action, presence: true, inclusion: { in: EVENT_METADATA }
  validates :occurred_at, presence: true
  validate :actor_matches_kind
  validate :metadata_is_safe

  scope :for_workspace, ->(workspace) { where(workspace: workspace) }
  scope :chronological, -> { order(occurred_at: :asc, id: :asc) }

  def self.record!(action:, source:, workspace: nil, actor: nil, actor_kind: nil, subject: nil, metadata: {}, request_id: nil, ip_address: nil, occurred_at: Time.current)
    ensure_subject_workspace!(subject, workspace)

    create!(
      action: action,
      source: source,
      workspace: workspace,
      actor: actor,
      actor_kind: actor ? actor_kind_for(actor) : actor_kind || "anonymous",
      subject_type: subject&.class&.base_class&.name,
      subject_id: subject&.id,
      metadata: metadata,
      request_id: request_id,
      ip_address: ip_address,
      occurred_at: occurred_at
    )
  end

  def readonly?
    persisted?
  end

  def self.actor_kind_for(actor)
    actor.break_glass? ? "break_glass" : "user"
  end
  private_class_method :actor_kind_for

  def self.ensure_subject_workspace!(subject, workspace)
    subject_workspace = subject if subject.is_a?(Workspace)
    subject_workspace ||= subject.workspace if subject.respond_to?(:workspace)
    return if subject_workspace.nil? || subject_workspace == workspace

    raise ArgumentError, "audit subject belongs to another workspace"
  end
  private_class_method :ensure_subject_workspace!

  private
    def actor_matches_kind
      actor_required = user? || break_glass?
      errors.add(:actor, "does not match actor kind") if actor_required != actor.present?
    end

    def metadata_is_safe
      unless metadata.is_a?(Hash)
        errors.add(:metadata, "must be an object")
        return
      end

      errors.add(:metadata, "is too large") if metadata.to_json.bytesize > MAX_METADATA_BYTES
      errors.add(:metadata, "contains a sensitive key") if sensitive_key?(metadata)
      errors.add(:metadata, "contains an unsupported key") if unsupported_metadata_key?
      errors.add(:metadata, "contains a non-scalar value") unless metadata.values.all? { |value| value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false }
      errors.add(:metadata, "contains an unsupported value") if unsupported_metadata_value?
    end

    def unsupported_metadata_key?
      allowed_keys = EVENT_METADATA.fetch(action, {}).keys
      (metadata.keys.map(&:to_s) - allowed_keys).any?
    end

    def unsupported_metadata_value?
      allowed_metadata = EVENT_METADATA.fetch(action, {})
      metadata.any? do |key, value|
        rule = allowed_metadata[key.to_s]
        rule && !metadata_value_matches?(value, rule)
      end
    end

    def metadata_value_matches?(value, rule)
      rule.is_a?(Array) ? rule.include?(value.to_s) : value.is_a?(rule)
    end

    def sensitive_key?(value)
      case value
      when Hash
        value.any? { |key, child| key.to_s.match?(SENSITIVE_KEY) || sensitive_key?(child) }
      when Array
        value.any? { |child| sensitive_key?(child) }
      else
        false
      end
    end
end
