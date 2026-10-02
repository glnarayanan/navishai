class AuditEvent < ApplicationRecord
  ACTOR_KINDS = %w[user break_glass system anonymous].freeze
  SOURCES = %w[web job task integration system].freeze
  SENSITIVE_KEY = /passw|email|secret|token|(?:\A|_)key(?:\z|_)|crypt|salt|certificate|otp|ssn|cvv|cvc/i
  MAX_METADATA_BYTES = 8.kilobytes
  EVENT_METADATA = {
    "authentication.failed" => { "method" => %w[local oidc break_glass] },
    "authentication.signed_out" => {},
    "authentication.succeeded" => { "method" => %w[local oidc break_glass] },
    "break_glass.configured" => {},
    "email_verification.completed" => {},
    "installation.bootstrapped" => {},
    "password_reset.completed" => {},
    "password_reset.requested" => {},
    "corpus.imported" => { "record_count" => Integer },
    "corpus.analysis_requested" => {},
    "corpus.analysis_completed" => {},
    "corpus.analysis_interrupted" => {},
    "assumption_impact.requested" => {},
    "assumption_impact.completed" => {},
    "assumption_impact.interrupted" => {},
    "source.deleted" => {},
    "source.downloaded" => {},
    "taxonomy.reviewed" => { "version" => Integer },
    "scenario.mined" => { "version" => Integer },
    "scenario.revised" => { "version" => Integer },
    "scenario.reviewed" => { "version" => Integer },
    "scenario.variant_created" => { "version" => Integer },
    "scenario.proposal_requested" => {},
    "scenario.proposal_completed" => {},
    "scenario.proposal_interrupted" => {},
    "trace.scenario_decided" => {},
    "trace.matching_requested" => {},
    "trace.matching_completed" => {},
    "trace.matching_interrupted" => {},
    "grader.version_created" => { "version" => Integer },
    "eval.compiled" => { "version" => Integer },
    "eval_suite.created" => {},
    "eval_suite.case_added" => {},
    "eval_suite.case_removed" => {},
    "calibration.created" => {},
    "calibration.sample_added" => {},
    "calibration.labelled" => {},
    "calibration.judge_requested" => {},
    "calibration.judge_completed" => {},
    "calibration.judge_interrupted" => {},
    "target.version_created" => { "version" => Integer },
    "evaluation.requested" => {},
    "evaluation.completed" => {},
    "evaluation.interrupted" => {},
    "regression.reviewed" => {},
    "workspace.created" => { "organization_id" => Integer },
    "workspace.updated" => {
      "previous_name" => String, "previous_slug" => String, "name" => String, "slug" => String
    },
    "workspace_invitation.accepted" => { "role" => Membership::ROLES },
    "workspace_invitation.created" => { "role" => Membership::ROLES },
    "workspace_invitation.revoked" => { "role" => Membership::ROLES }
  }.freeze

  belongs_to :workspace, optional: true
  belongs_to :actor, class_name: "User", optional: true

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
    create!(action:, source:, workspace:, actor:,
      actor_kind: actor ? actor_kind_for(actor) : actor_kind || "anonymous",
      subject_type: subject&.class&.base_class&.name, subject_id: subject&.id,
      metadata:, request_id:, ip_address:, occurred_at:)
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
      (metadata.keys.map(&:to_s) - EVENT_METADATA.fetch(action, {}).keys).any?
    end

    def unsupported_metadata_value?
      allowed_metadata = EVENT_METADATA.fetch(action, {})
      metadata.any? do |key, value|
        rule = allowed_metadata[key.to_s]
        rule && !(rule.is_a?(Array) ? rule.include?(value.to_s) : value.is_a?(rule))
      end
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
