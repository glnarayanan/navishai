class AccountHealthInput < ApplicationRecord
  INPUTS = {
    "renewal_on" => "date",
    "contract_value" => "number",
    "active_users" => "number",
    "licensed_seats" => "number"
  }.freeze
  SOURCE_KINDS = %w[csv api].freeze
  CORRECTION_PRIORITY_ORDER = Arel.sql(
    "CASE WHEN account_health_inputs.corrects_account_health_input_id IS NULL THEN 1 ELSE 0 END ASC"
  )

  belongs_to :workspace
  belongs_to :account
  belongs_to :supplied_by_membership, class_name: "Membership", optional: true
  belongs_to :supplied_by_user, class_name: "User", optional: true
  belongs_to :corrects_input, class_name: "AccountHealthInput",
    foreign_key: :corrects_account_health_input_id, optional: true
  has_many :corrections, class_name: "AccountHealthInput",
    foreign_key: :corrects_account_health_input_id, dependent: :restrict_with_exception,
    inverse_of: :corrects_input

  validates :input_key, inclusion: { in: INPUTS }
  validates :value_kind, inclusion: { in: INPUTS.values.uniq }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :source_key, :source_namespace, :source_digest, :source_locator, :observed_at, presence: true
  validates :source_namespace, format: { with: /\A[a-z][a-z0-9_.:-]{0,99}\z/ }
  validates :source_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :typed_value_matches_key
  validate :validity_is_ordered
  validate :correction_matches_source

  scope :effective_heads, -> {
    where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM account_health_inputs corrections
        WHERE corrections.workspace_id = account_health_inputs.workspace_id
          AND corrections.account_id = account_health_inputs.account_id
          AND corrections.input_key = account_health_inputs.input_key
          AND corrections.corrects_account_health_input_id = account_health_inputs.id
      )
    SQL
  }
  scope :eligible_at, ->(time) {
    where("account_health_inputs.observed_at <= ?", time)
      .where("account_health_inputs.valid_from IS NULL OR account_health_inputs.valid_from <= ?", time)
      .where("account_health_inputs.valid_until IS NULL OR account_health_inputs.valid_until >= ?", time)
  }
  scope :prioritized, -> {
    order(CORRECTION_PRIORITY_ORDER, observed_at: :desc, id: :desc)
  }

  def self.effective_for(workspace:, account_ids:, input_key: nil, at: Time.current, one_per_key: false)
    relation = workspace.account_health_inputs.where(workspace_id: workspace.id, account_id: account_ids)
    relation = relation.where(input_key:) if input_key
    relation = relation.effective_heads.eligible_at(at)
    if one_per_key
      relation = relation.select("DISTINCT ON (account_health_inputs.input_key) account_health_inputs.*")
        .reorder(:input_key)
    end
    relation.prioritized
  end

  def readonly? = persisted?

  private
    def typed_value_matches_key
      errors.add(:value_kind, "does not match input") unless INPUTS[input_key] == value_kind
      valid = value_kind == "date" ? date_value.present? && numeric_value.nil? : numeric_value.present? && date_value.nil?
      errors.add(:base, "value does not match its type") unless valid
    end

    def validity_is_ordered
      errors.add(:valid_until, "must not precede valid from") if valid_from && valid_until && valid_until < valid_from
    end

    def correction_matches_source
      return unless corrects_input

      unless corrects_input.workspace_id == workspace_id && corrects_input.account_id == account_id &&
          corrects_input.input_key == input_key && corrects_input.source_namespace == source_namespace &&
          corrects_input.id != id
        errors.add(:corrects_input, "must be an earlier matching observation")
      end
    end
end
