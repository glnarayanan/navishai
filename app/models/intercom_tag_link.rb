class IntercomTagLink < ApplicationRecord
  belongs_to :workspace
  belongs_to :intercom_connection
  belongs_to :tag

  validates :remote_tag_id, presence: true, uniqueness: { scope: :intercom_connection_id }
end
