class IntercomPartAttachment < ApplicationRecord
  belongs_to :workspace
  belongs_to :intercom_part_link
  belongs_to :stored_attachment

  validates :remote_attachment_id, presence: true, length: { maximum: 255 },
    uniqueness: { scope: :intercom_part_link_id }
  validate :records_stay_in_workspace

  private
    def records_stay_in_workspace
      errors.add(:base, "records belong to another workspace") if
        [ intercom_part_link, stored_attachment ].compact.any? { |record| record.workspace_id != workspace_id }
    end
end
