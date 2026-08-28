class CrewTaskEvent < ApplicationRecord
  KINDS = %w[created status_changed handoff comment evidence_added review_requested review_resolved outcome_recorded].freeze
  SOURCES = %w[web task runner system].freeze
  EVIDENCE_KINDS = %w[conversation case account knowledge public_web other].freeze
  REVIEW_OUTCOMES = %w[approved changes_requested].freeze
  OUTCOME_KINDS = %w[completed failed canceled].freeze

  belongs_to :workspace
  belongs_to :crew_task
  belongs_to :actor_membership, class_name: "Membership", optional: true
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :from_agent_profile, class_name: "AgentProfile", optional: true
  belongs_to :to_agent_profile, class_name: "AgentProfile"
  belongs_to :from_agent_profile_version, class_name: "AgentProfileVersion", optional: true
  belongs_to :to_agent_profile_version, class_name: "AgentProfileVersion"
  belongs_to :from_governed_policy_publication, class_name: "GovernedPolicyPublication", optional: true
  belongs_to :to_governed_policy_publication, class_name: "GovernedPolicyPublication", optional: true
  belongs_to :from_resolution_contract_version, class_name: "ResolutionContractVersion", optional: true
  belongs_to :to_resolution_contract_version, class_name: "ResolutionContractVersion", optional: true

  enum :event_kind, KINDS.index_by(&:itself), validate: true
  enum :source, SOURCES.index_by(&:itself), prefix: true, validate: true

  validates :sequence_number, numericality: { only_integer: true, greater_than: 0 }
  validates :evidence_kind, inclusion: { in: EVIDENCE_KINDS }, allow_nil: true
  validates :review_outcome, inclusion: { in: REVIEW_OUTCOMES }, allow_nil: true
  validates :outcome_kind, inclusion: { in: OUTCOME_KINDS }, allow_nil: true
  validate :actor_is_consistent
  validate :policy_history_is_consistent
  validate :content_fits

  def readonly?
    persisted?
  end

  private
    def actor_is_consistent
      if actor_membership.nil? != actor_user.nil?
        errors.add(:actor_membership, "and user must both be set")
      elsif actor_membership &&
          (actor_membership.workspace_id != workspace_id || actor_membership.user_id != actor_user_id)
        errors.add(:actor_membership, "does not match workspace and user")
      end
    end

    def content_fits
      errors.add(:body, "must be 20,000 bytes or less") if body.to_s.bytesize > 20_000
      errors.add(:evidence_locator, "must be 2,000 bytes or less") if evidence_locator.to_s.bytesize > 2_000
    end

    def policy_history_is_consistent
      %w[from to].each do |direction|
        publication = public_send("#{direction}_governed_policy_publication")
        next unless publication

        unless publication.workspace_id == workspace_id &&
            publication.resolution_contract_version_id == public_send("#{direction}_resolution_contract_version_id") &&
            publication.agent_profile_version_id == public_send("#{direction}_agent_profile_version_id")
          errors.add("#{direction}_governed_policy_publication", "does not match frozen policy history")
        end
      end
    end
end
