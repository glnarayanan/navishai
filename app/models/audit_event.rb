class AuditEvent < ApplicationRecord
  ACTOR_KINDS = %w[user break_glass system anonymous].freeze
  SOURCES = %w[web job task runner integration system].freeze
  SENSITIVE_KEY = /passw|email|secret|token|key|crypt|salt|certificate|otp|ssn|cvv|cvc/i
  MAX_METADATA_BYTES = 8.kilobytes
  EVENT_METADATA_KEYS = {
    "authentication.failed" => %w[method],
    "authentication.signed_out" => [],
    "authentication.succeeded" => %w[method],
    "break_glass.configured" => [],
    "email_verification.completed" => [],
    "installation.bootstrapped" => [],
    "password_reset.completed" => [],
    "password_reset.requested" => [],
    "workspace_invitation.accepted" => %w[role],
    "workspace_invitation.created" => %w[role],
    "workspace_invitation.revoked" => %w[role]
  }.freeze

  belongs_to :workspace, optional: true
  belongs_to :actor, class_name: "User", optional: true

  enum :actor_kind, ACTOR_KINDS.index_by(&:itself), validate: true
  enum :source, SOURCES.index_by(&:itself), prefix: true, validate: true

  validates :action, presence: true, inclusion: { in: EVENT_METADATA_KEYS }
  validates :occurred_at, presence: true
  validate :actor_matches_kind
  validate :metadata_is_safe

  scope :for_workspace, ->(workspace) { where(workspace: workspace) }
  scope :chronological, -> { order(occurred_at: :asc, id: :asc) }

  def self.record!(action:, source:, workspace: nil, actor: nil, actor_kind: nil, subject: nil, metadata: {}, request_id: nil, ip_address: nil, occurred_at: Time.current)
    create!(
      action: action,
      source: source,
      workspace: workspace,
      actor: actor,
      actor_kind: actor_kind || actor_kind_for(actor),
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
    return "anonymous" unless actor

    actor.break_glass? ? "break_glass" : "user"
  end
  private_class_method :actor_kind_for

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
    end

    def unsupported_metadata_key?
      allowed_keys = EVENT_METADATA_KEYS.fetch(action, [])
      (metadata.keys.map(&:to_s) - allowed_keys).any?
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
