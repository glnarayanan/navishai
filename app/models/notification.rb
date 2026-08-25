class Notification < ApplicationRecord
  CATEGORIES = %w[assignment review sla failure blocked completion].freeze

  belongs_to :workspace
  belongs_to :recipient_membership, class_name: "Membership"
  belongs_to :source_audit_event, class_name: "AuditEvent"

  enum :category, CATEGORIES.index_by(&:itself), validate: true, prefix: true

  validates :source_audit_event_id, uniqueness: { scope: :recipient_membership_id }
  validates :title, presence: true, length: { maximum: 200 }
  validates :path, presence: true, length: { maximum: 1_000 }, format: { with: /\A\/(?!\/).+\z/ }
  validates :occurred_at, presence: true
  validate :read_time_follows_event

  scope :newest_first, -> { order(occurred_at: :desc, id: :desc) }
  scope :unread, -> { where(read_at: nil) }

  private
    def read_time_follows_event
      errors.add(:read_at, "cannot predate the event") if read_at && occurred_at && read_at < occurred_at
    end
end
