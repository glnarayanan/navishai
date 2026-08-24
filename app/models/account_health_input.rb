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

  validates :input_key, inclusion: { in: INPUTS }
  validates :value_kind, inclusion: { in: INPUTS.values.uniq }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :source_key, :source_locator, :observed_at, presence: true
  validate :typed_value_matches_key

  def readonly? = persisted?

  private
    def typed_value_matches_key
      errors.add(:value_kind, "does not match input") unless INPUTS[input_key] == value_kind
      valid = value_kind == "date" ? date_value.present? && numeric_value.nil? : numeric_value.present? && date_value.nil?
      errors.add(:base, "value does not match its type") unless valid
    end
end
