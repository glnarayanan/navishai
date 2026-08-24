class OutboundEmailDelivery < ApplicationRecord
  STATUSES = %w[sending sent failed unknown].freeze
  FAILURE_CODES = %w[configuration_error rejected unknown_outcome confirmed_not_sent].freeze

  belongs_to :workspace
  belongs_to :email_draft
  belongs_to :shared_email_inbox
  belongs_to :email_thread
  belongs_to :conversation
  belongs_to :conversation_message, optional: true
  belongs_to :actor_membership, class_name: "Membership"
  belongs_to :actor_user, class_name: "User"

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :idempotency_key, :message_id, :from_address, :to_address, :subject, :body, :started_at, presence: true
  validates :idempotency_key, uniqueness: { scope: :workspace_id }, length: { maximum: 100 }
  validates :message_id, uniqueness: { scope: :shared_email_inbox_id }, length: { maximum: 998 }
  validates :failure_code, inclusion: { in: FAILURE_CODES }, allow_nil: true
  validate :records_match

  private
    def records_match
      records = [ email_draft, shared_email_inbox, email_thread, conversation, actor_membership ]
      errors.add(:base, "records belong to another workspace") if records.compact.any? { |record| record.workspace_id != workspace_id }
      errors.add(:conversation, "does not match thread") if email_thread && conversation != email_thread.conversation
      errors.add(:actor_user, "does not match membership") if actor_membership && actor_user != actor_membership.user
    end
end
