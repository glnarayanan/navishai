class ServiceCalendarHoliday < ApplicationRecord
  belongs_to :workspace
  belongs_to :service_calendar

  normalizes :name, with: ->(name) { name.strip }
  validates :name, presence: true, length: { maximum: 100 }
  validates :date, presence: true, uniqueness: { scope: :service_calendar_id }
  validate :calendar_belongs_to_workspace

  private
    def calendar_belongs_to_workspace
      errors.add(:service_calendar, "belongs to another workspace") if service_calendar && service_calendar.workspace_id != workspace_id
    end
end
