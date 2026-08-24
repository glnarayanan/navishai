class IntercomSyncOperation < ApplicationRecord
  OPERATION_KINDS = %w[note assign tag untag].freeze
  STATUSES = %w[pending sending completed failed unknown].freeze
  MAX_ATTEMPTS = 5

  belongs_to :workspace
  belongs_to :intercom_connection
  belongs_to :intercom_conversation_link
  belongs_to :membership
  belongs_to :user

  has_secure_token :operation_key

  enum :operation_kind, OPERATION_KINDS.index_by(&:itself), validate: true
  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :operation_key, presence: true, uniqueness: true
  validate :actor_tuple_matches

  scope :retryable, -> { where(status: :failed).where("attempt_count < ?", MAX_ATTEMPTS) }

  private
    def actor_tuple_matches
      errors.add(:user, "must match the membership") if membership && user_id != membership.user_id
      errors.add(:membership, "must belong to the workspace") if membership && membership.workspace_id != workspace_id
    end
end
