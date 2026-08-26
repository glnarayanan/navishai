class IntercomOutboundDelivery < ApplicationRecord
  STATUSES = %w[sending sent failed unknown].freeze
  FAILURE_CODES = %w[configuration_error remote_rejected authorization_changed unknown_outcome confirmed_not_sent].freeze

  belongs_to :workspace
  belongs_to :intercom_draft
  belongs_to :intercom_connection
  belongs_to :intercom_conversation_link
  belongs_to :conversation
  belongs_to :conversation_message, optional: true
  belongs_to :actor_membership, class_name: "Membership"
  belongs_to :actor_user, class_name: "User"

  enum :status, STATUSES.index_by(&:itself), validate: true
  validates :idempotency_key, :remote_conversation_id, :source_part_id, :admin_id, :body, :started_at, presence: true
  validates :idempotency_key, uniqueness: { scope: :workspace_id }, length: { maximum: 100 }
  validates :failure_code, inclusion: { in: FAILURE_CODES }, allow_nil: true
  validate :records_match

  private
    def records_match
      records = [ intercom_draft, intercom_connection, intercom_conversation_link, conversation, actor_membership ]
      errors.add(:base, "records belong to another workspace") if records.compact.any? { |record| record.workspace_id != workspace_id }
      errors.add(:conversation, "does not match Intercom link") if intercom_conversation_link && intercom_conversation_link.conversation != conversation
      errors.add(:actor_user, "does not match membership") if actor_membership && actor_user != actor_membership.user
    end
end
