class PersonalProviderAccount < ApplicationRecord
  STATES = %w[starting pending connected failed disconnected].freeze

  belongs_to :workspace
  belongs_to :membership
  has_one :runtime_installation, dependent: :restrict_with_exception
  attribute :account_key, default: -> { SecureRandom.uuid }
  enum :state, STATES.index_by(&:itself), validate: true
  validates :account_key, format: { with: RunnerProtocol::UUID_PATTERN }, uniqueness: true
  validate :membership_in_workspace

  def usable?
    connected? && membership.can_write? && runtime_installation&.runnable?
  end

  private
    def membership_in_workspace
      errors.add(:membership, "belongs to another workspace") if membership && membership.workspace_id != workspace_id
    end
end
