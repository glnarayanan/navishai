class MemoryProposal < ApplicationRecord
  MEMORY_TYPES = %w[semantic profile].freeze
  SCOPE_KINDS = %w[account contact support_case].freeze
  STATUSES = %w[proposed accepted rejected].freeze

  belongs_to :workspace
  belongs_to :source_crew_artifact, class_name: "CrewArtifact"
  belongs_to :source_agent_profile, class_name: "AgentProfile"
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :support_case, optional: true
  belongs_to :reviewed_by_membership, class_name: "Membership", optional: true
  belongs_to :reviewed_by_user, class_name: "User", optional: true
  belongs_to :published_memory_record, class_name: "MemoryRecord", optional: true

  enum :memory_type, MEMORY_TYPES.index_by(&:itself), validate: true, prefix: true
  enum :scope_kind, SCOPE_KINDS.index_by(&:itself), validate: true, prefix: true
  enum :status, STATUSES.index_by(&:itself), validate: true

  normalizes :topic, with: ->(value) { value.strip }
  validates :topic, presence: true, length: { maximum: 200 }
  validates :content, presence: true, length: { maximum: 32_768 }
  validates :content_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validate :source_matches_workspace
  validate :scope_matches_workspace

  before_validation :set_content_digest

  def scope_target
    public_send(scope_kind)
  end

  private
    def set_content_digest
      self.content_digest = Digest::SHA256.hexdigest(content.to_s.b)
    end

    def source_matches_workspace
      records = [ source_crew_artifact, source_agent_profile ].compact
      errors.add(:base, "source belongs to another workspace") if records.any? { |record| record.workspace_id != workspace_id }
    end

    def scope_matches_workspace
      target = scope_kind.in?(SCOPE_KINDS) && public_send(scope_kind)
      errors.add(:scope_kind, "does not match its target") unless target && target.workspace_id == workspace_id
    end
end
