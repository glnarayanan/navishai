class ConversationMessage < ApplicationRecord
  DIRECTIONS = %w[inbound outbound].freeze
  AUTHOR_KINDS = %w[contact user external].freeze

  belongs_to :workspace
  belongs_to :conversation
  belongs_to :author_contact, class_name: "Contact", optional: true
  belongs_to :author_user, class_name: "User", optional: true
  belongs_to :in_reply_to, class_name: "ConversationMessage", optional: true

  enum :direction, DIRECTIONS.index_by(&:itself), validate: true
  enum :author_kind, AUTHOR_KINDS.index_by(&:itself), validate: true

  validates :body, presence: true
  validates :occurred_at, presence: true
  validates :external_author_name, presence: true, length: { maximum: 200 }, if: :external?
  validate :author_matches_kind

  def readonly?
    persisted?
  end

  private
    def author_matches_kind
      expected_contact = contact?
      errors.add(:author_user, "does not match author kind") if user? != author_user.present?
      errors.add(:author_contact, "does not match author kind") if expected_contact != author_contact.present?
      errors.add(:external_author_name, "does not match author kind") if external? != external_author_name.present?
    end
end
