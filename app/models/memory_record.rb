class MemoryRecord < ApplicationRecord
  MEMORY_TYPES = %w[episodic semantic profile procedural].freeze
  SCOPE_KINDS = %w[organization workspace account contact support_case crew agent user].freeze
  AUTHORITIES = %w[inference source_record human_correction].freeze
  ORIGIN_KINDS = %w[system agent human].freeze
  RETENTION_POLICIES = %w[indefinite time_bound source_lifetime].freeze

  belongs_to :workspace
  belongs_to :organization, optional: true
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :support_case, optional: true
  belongs_to :crew_template, optional: true
  belongs_to :agent_profile, optional: true
  belongs_to :user, optional: true
  belongs_to :source_agent_profile, class_name: "AgentProfile", optional: true
  belongs_to :source_membership, class_name: "Membership", optional: true
  belongs_to :source_user, class_name: "User", optional: true
  belongs_to :supersedes_memory_record, class_name: "MemoryRecord", optional: true
  has_many :revisions, class_name: "MemoryRecord", foreign_key: :supersedes_memory_record_id,
    dependent: :restrict_with_exception, inverse_of: :supersedes_memory_record

  enum :memory_type, MEMORY_TYPES.index_by(&:itself), validate: true, prefix: true
  enum :scope_kind, SCOPE_KINDS.index_by(&:itself), validate: true, prefix: true
  enum :authority, AUTHORITIES.index_by(&:itself), validate: true, prefix: true
  enum :origin_kind, ORIGIN_KINDS.index_by(&:itself), validate: true, prefix: true
  enum :retention_policy, RETENTION_POLICIES.index_by(&:itself), validate: true, prefix: true

  normalizes :topic, with: ->(value) { value.strip }
  normalizes :source_reference, with: ->(value) { value.strip }

  validates :topic, presence: true, length: { maximum: 200 }
  validates :content, presence: true, length: { maximum: 32_768 }
  validates :source_reference, presence: true, length: { maximum: 2_048 }
  validates :observed_at, :valid_from, presence: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :content_digest, :source_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :supersession_keeps_contract
  validate :supersession_keeps_authority
  validate :human_correction_is_authorized
  validate :procedural_memory_is_human_authorized

  before_validation :set_content_digest

  scope :current, -> {
    where("NOT EXISTS (SELECT 1 FROM memory_records revisions WHERE revisions.supersedes_memory_record_id = memory_records.id)")
  }
  scope :prioritized, -> {
    order(Arel.sql("CASE authority WHEN 'human_correction' THEN 0 WHEN 'source_record' THEN 1 ELSE 2 END"),
      confidence: :desc, observed_at: :desc, id: :desc)
  }
  scope :eligible_at, ->(time) {
    where("valid_from <= ? AND (valid_until IS NULL OR valid_until > ?)", time, time)
      .where("retention_policy <> 'time_bound' OR retention_until > ?", time)
  }

  def readonly?
    persisted?
  end

  def scope_target
    return workspace if scope_kind_workspace?

    case scope_kind
    when "crew" then crew_template
    when "agent" then agent_profile
    else public_send(scope_kind)
    end
  end

  private
    def set_content_digest
      self.content_digest = Digest::SHA256.hexdigest(content.to_s.b)
    end

    def supersession_keeps_contract
      prior = supersedes_memory_record
      return unless prior

      expected = [ workspace_id, memory_type, scope_kind, topic, organization_id, account_id, contact_id,
        support_case_id, crew_template_id, agent_profile_id, user_id ]
      actual = [ prior.workspace_id, prior.memory_type, prior.scope_kind, prior.topic, prior.organization_id,
        prior.account_id, prior.contact_id, prior.support_case_id, prior.crew_template_id,
        prior.agent_profile_id, prior.user_id ]
      errors.add(:supersedes_memory_record, "must keep its workspace, type, topic, and scope") unless expected == actual
    end

    def supersession_keeps_authority
      return unless supersedes_memory_record && authority.in?(AUTHORITIES)

      rank = AUTHORITIES.index(authority)
      prior_rank = AUTHORITIES.index(supersedes_memory_record.authority)
      errors.add(:authority, "cannot rank below the superseded memory") if rank < prior_rank
    end

    def human_correction_is_authorized
      return unless authority_human_correction?
      return if source_membership&.can_manage_work? && source_membership.user_id == source_user_id &&
        source_membership.workspace_id == workspace_id

      errors.add(:source_membership, "must be an authorized workspace member")
    end

    def procedural_memory_is_human_authorized
      return unless memory_type_procedural?

      errors.add(:authority, "must be an authorized human assertion") unless authority_human_correction?
    end
end
