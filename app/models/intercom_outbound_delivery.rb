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
  belongs_to :source_crew_artifact, class_name: "CrewArtifact", optional: true
  belongs_to :human_edited_by_membership, class_name: "Membership", optional: true
  belongs_to :human_edited_by_user, class_name: "User", optional: true

  enum :status, STATUSES.index_by(&:itself), validate: true
  validates :idempotency_key, :remote_conversation_id, :source_part_id, :admin_id, :body, :started_at, presence: true
  validates :idempotency_key, uniqueness: { scope: :workspace_id }, length: { maximum: 100 }
  validates :failure_code, inclusion: { in: FAILURE_CODES }, allow_nil: true
  validates :generated_body_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :generated_contract_result_state, inclusion: { in: CrewArtifact::CONTRACT_RESULTS }, allow_nil: true
  validate :records_match

  private
    def records_match
      records = [
        intercom_draft, intercom_connection, intercom_conversation_link, conversation, actor_membership,
        source_crew_artifact, human_edited_by_membership
      ]
      errors.add(:base, "records belong to another workspace") if records.compact.any? { |record| record.workspace_id != workspace_id }
      errors.add(:conversation, "does not match Intercom link") if intercom_conversation_link && intercom_conversation_link.conversation != conversation
      errors.add(:actor_user, "does not match membership") if actor_membership && actor_user != actor_membership.user
      if human_edited_by_membership && human_edited_by_user != human_edited_by_membership.user
        errors.add(:human_edited_by_user, "does not match membership")
      end
      if source_crew_artifact &&
          (!source_crew_artifact.draft? || source_crew_artifact.crew_task.support_case_id != intercom_draft&.support_case_id)
        errors.add(:source_crew_artifact, "does not belong to this Support case")
      end
    end
end
