class SupportCaseTagging < ApplicationRecord
  belongs_to :workspace
  belongs_to :support_case
  belongs_to :tag
  belongs_to :source_intercom_connection, class_name: "IntercomConnection", optional: true

  validates :tag_id, uniqueness: { scope: :support_case_id }
  validate :source_connection_stays_in_workspace

  private
    def source_connection_stays_in_workspace
      return unless source_intercom_connection && source_intercom_connection.workspace_id != workspace_id

      errors.add(:source_intercom_connection, "must belong to the workspace")
    end
end
