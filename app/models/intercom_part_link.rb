class IntercomPartLink < ApplicationRecord
  PART_TYPES = %w[contact_reply admin_reply note].freeze

  belongs_to :workspace
  belongs_to :intercom_connection
  belongs_to :intercom_conversation_link
  belongs_to :conversation
  belongs_to :conversation_message, optional: true
  has_many :intercom_part_attachments, dependent: :restrict_with_exception
  has_many :stored_attachments, through: :intercom_part_attachments

  enum :part_type, PART_TYPES.index_by(&:itself), validate: true
  validates :remote_part_id, presence: true, uniqueness: { scope: :intercom_connection_id }
  validates :body, :source_digest, :remote_created_at, presence: true
end
