class AccountHealthInput < ApplicationRecord
  INPUTS = {
    "renewal_on" => "date",
    "contract_value" => "number",
    "active_users" => "number",
    "licensed_seats" => "number"
  }.freeze
  SOURCE_KINDS = %w[csv api].freeze

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
