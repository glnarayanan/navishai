class EmailDraft < ApplicationRecord
  STATUSES = %w[ready sending sent].freeze
  MAX_BODY_BYTES = 1.megabyte

  belongs_to :workspace
  belongs_to :support_case
  belongs_to :email_thread
  belongs_to :conversation
  belongs_to :updated_by, class_name: "User"
  belongs_to :source_crew_artifact, class_name: "CrewArtifact", optional: true
  belongs_to :human_edited_by_membership, class_name: "Membership", optional: true
  belongs_to :human_edited_by_user, class_name: "User", optional: true
  has_many :outbound_email_deliveries, dependent: :restrict_with_exception
  has_many :email_draft_attachments, dependent: :destroy
  has_many :stored_attachments, through: :email_draft_attachments

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :body, presence: true
  validates :generated_body_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :generated_contract_result_state, inclusion: { in: CrewArtifact::CONTRACT_RESULTS }, allow_nil: true
  validate :body_size
  validate :records_match
  validate :provenance_matches

  private
    def body_size
      errors.add(:body, "is too large") if body.to_s.bytesize > MAX_BODY_BYTES
    end

    def records_match
      records = [ support_case, email_thread, conversation ]
      if records.all?(&:present?) && [ support_case.conversation_id, email_thread.conversation_id ].any? { |id| id != conversation_id }
        errors.add(:email_thread, "does not match case")
      end
      errors.add(:base, "records belong to another workspace") if records.compact.any? { |record| record.workspace_id != workspace_id }
    end

    def provenance_matches
      if source_crew_artifact &&
          (!source_crew_artifact.draft? || source_crew_artifact.crew_task.support_case_id != support_case_id)
        errors.add(:source_crew_artifact, "does not belong to this Support case")
      end
      records = [ source_crew_artifact, human_edited_by_membership ].compact
      errors.add(:base, "provenance belongs to another workspace") if records.any? { |record| record.workspace_id != workspace_id }
      if human_edited_by_membership && human_edited_by_user != human_edited_by_membership.user
        errors.add(:human_edited_by_user, "does not match membership")
      end
    end
end
