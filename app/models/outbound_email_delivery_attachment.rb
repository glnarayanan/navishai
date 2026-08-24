class OutboundEmailDeliveryAttachment < ApplicationRecord
  belongs_to :workspace
  belongs_to :outbound_email_delivery
  belongs_to :stored_attachment

  validate :records_match

  private
    def records_match
      records = [ outbound_email_delivery, stored_attachment ]
      errors.add(:base, "records belong to another workspace") if records.compact.any? { |record| record.workspace_id != workspace_id }
      errors.add(:stored_attachment, "is not available") unless stored_attachment&.available?
    end
end
