class StoredAttachment < ApplicationRecord
  SOURCES = %w[inbound_email user_upload].freeze
  SCAN_STATUSES = %w[quarantined available rejected].freeze
  MAX_BYTES = 5.megabytes

  belongs_to :workspace
  belongs_to :uploaded_by_membership, class_name: "Membership", optional: true
  belongs_to :uploaded_by_user, class_name: "User", optional: true
  has_one_attached :file
  has_many :conversation_message_attachments, dependent: :restrict_with_exception
  has_many :conversation_messages, through: :conversation_message_attachments
  has_many :email_draft_attachments, dependent: :restrict_with_exception
  has_many :email_drafts, through: :email_draft_attachments
  has_many :outbound_email_delivery_attachments, dependent: :restrict_with_exception
  has_many :outbound_email_deliveries, through: :outbound_email_delivery_attachments

  enum :source, SOURCES.index_by(&:itself), validate: true
  enum :scan_status, SCAN_STATUSES.index_by(&:itself), validate: true

  validates :filename, :content_sha256, :detected_content_type, :scan_result_code, presence: true
  validates :filename, length: { maximum: 255 }
  validates :content_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :byte_size, numericality: { only_integer: true, in: 1..MAX_BYTES }
  validate :actor_matches_source
  validate :blob_matches_record

  def download_verified!
    content = file.download
    valid_size = content.bytesize == byte_size
    actual_sha256 = Digest::SHA256.hexdigest(content)
    valid_digest = ActiveSupport::SecurityUtils.secure_compare(actual_sha256, content_sha256)
    raise ActiveStorage::IntegrityError unless valid_size && valid_digest

    content
  end

  private
    def actor_matches_source
      if user_upload?
        errors.add(:uploaded_by_membership, "is required") unless uploaded_by_membership
        errors.add(:uploaded_by_user, "does not match membership") unless uploaded_by_membership&.user == uploaded_by_user
      elsif uploaded_by_membership || uploaded_by_user
        errors.add(:base, "inbound attachments cannot have a user actor")
      end
    end

    def blob_matches_record
      return unless file.attached?

      errors.add(:file, "size does not match") unless file.blob.byte_size == byte_size
      errors.add(:file, "type does not match") unless file.blob.content_type == detected_content_type
    end
end
