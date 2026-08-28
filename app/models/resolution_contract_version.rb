class ResolutionContractVersion < ApplicationRecord
  CLAIM_CATEGORIES = {
    "customer_account_fact" => "Customer or Account facts",
    "product_technical_fact" => "Product or technical facts",
    "policy_entitlement" => "Policy or entitlement statements",
    "promised_action_date" => "Promised actions or dates"
  }.freeze
  SOURCE_KINDS = {
    "knowledge" => "Knowledge",
    "conversation" => "Conversation",
    "case" => "Case",
    "account" => "Account",
    "health_signal" => "Health signal",
    "public_web" => "Public web",
    "memory" => "Memory"
  }.freeze
  REVIEW_CHECKS = {
    "claims_grounded" => "Claims are grounded",
    "conflicts_resolved" => "Conflicts are resolved",
    "uncertainty_stated" => "Uncertainty is stated",
    "human_authority_preserved" => "Human authority is preserved"
  }.freeze
  EXECUTION_BUDGET_RANGE = 1..20_000_000
  FRESHNESS_DAYS_RANGE = 1..3_650

  belongs_to :workspace
  belongs_to :resolution_contract_family
  belongs_to :created_by_membership, class_name: "Membership", optional: true
  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :crew_artifacts, dependent: :restrict_with_exception
  has_many :governed_policy_proposals, dependent: :restrict_with_exception

  validates :version_number, numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :resolution_contract_family_id }
  validates :execution_budget_units, numericality: { only_integer: true, in: EXECUTION_BUDGET_RANGE }
  validates :missing_items_block, inclusion: { in: [ true, false ] }
  validate :configuration_is_bounded
  validate :records_are_consistent

  def readonly?
    persisted?
  end

  def published?
    resolution_contract_family.current_version_id == id
  end

  private
    def configuration_is_bounded
      validate_bounded_list(:required_claim_categories, CLAIM_CATEGORIES.keys)
      validate_bounded_list(:mandatory_review_checks, REVIEW_CHECKS.keys)
      unless evidence_freshness_days.is_a?(Hash) && evidence_freshness_days.keys.sort == SOURCE_KINDS.keys.sort &&
          evidence_freshness_days.values.all? { |value| value.is_a?(Integer) && value.in?(FRESHNESS_DAYS_RANGE) }
        errors.add(:evidence_freshness_days, "must set bounded days for every supported source")
      end
    end

    def validate_bounded_list(attribute, allowed)
      value = public_send(attribute)
      unless value.is_a?(Array) && value.any? && value == value.uniq.sort && (value - allowed).empty?
        errors.add(attribute, "must contain distinct supported values")
      end
    end

    def records_are_consistent
      if resolution_contract_family && resolution_contract_family.workspace_id != workspace_id
        errors.add(:resolution_contract_family, "belongs to another Workspace")
      end
      if created_by_membership.nil? != created_by_user.nil?
        errors.add(:created_by_membership, "and user must both be set")
      elsif created_by_membership &&
          (created_by_membership.workspace_id != workspace_id || created_by_membership.user_id != created_by_user_id)
        errors.add(:created_by_membership, "does not match Workspace and user")
      end
    end
end
