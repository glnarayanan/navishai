class SupportCaseStatusChange < ApplicationRecord
  SOURCES = AuditEvent::SOURCES.freeze
  ACTOR_KINDS = %w[user system].freeze

  belongs_to :workspace
  belongs_to :support_case
  belongs_to :actor, class_name: "User", optional: true

  enum :source, SOURCES.index_by(&:itself), prefix: true, validate: true
  enum :actor_kind, ACTOR_KINDS.index_by(&:itself), validate: true

  validates :from_status, inclusion: { in: SupportCase::STATUSES }, allow_nil: true
  validates :to_status, inclusion: { in: SupportCase::STATUSES }
  validates :reason, presence: true, length: { maximum: 500 }
  validates :occurred_at, presence: true
  validate :actor_matches_kind

  def readonly?
    persisted?
  end

  private
    def actor_matches_kind
      errors.add(:actor, "does not match actor kind") if user? != actor.present?
    end
end
