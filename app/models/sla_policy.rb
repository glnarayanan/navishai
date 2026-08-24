class SlaPolicy < ApplicationRecord
  belongs_to :workspace
  belongs_to :service_calendar
  has_many :case_slas, dependent: :restrict_with_exception

  enum :priority, SupportCase::PRIORITIES.index_by(&:itself), validate: true

  normalizes :name, with: ->(name) { name.strip }
  validates :name, presence: true, length: { maximum: 100 }
  validates :first_response_minutes, :resolution_minutes, numericality: { only_integer: true, greater_than: 0 }
  validates :warning_percent, numericality: { only_integer: true, in: 1..99 }
  validates :priority, uniqueness: { scope: :workspace_id, conditions: -> { where(active: true) } }, if: :active?
  validate :calendar_belongs_to_workspace

  scope :active, -> { where(active: true) }

  private
    def calendar_belongs_to_workspace
      errors.add(:service_calendar, "belongs to another workspace") if service_calendar && service_calendar.workspace_id != workspace_id
    end
end
