class EmailDraftAttachment < ApplicationRecord
  belongs_to :workspace
  belongs_to :email_draft
  belongs_to :stored_attachment

  validate :records_match

  private
    def records_match
      errors.add(:base, "records belong to another workspace") if [ email_draft, stored_attachment ].compact.any? { |record| record.workspace_id != workspace_id }
    end
end
