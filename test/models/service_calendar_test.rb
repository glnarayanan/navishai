require "test_helper"

class ServiceCalendarTest < ActiveSupport::TestCase
  test "adds business minutes across closing time, weekends, and holidays" do
    calendar = service_calendar
    calendar.holidays.create!(workspace: calendar.workspace, date: Date.new(2026, 12, 22), name: "Winter holiday")
    start_time = Time.find_zone!(calendar.time_zone).local(2026, 12, 21, 16, 0)

    result = calendar.add_business_minutes(start_time, 120)

    assert_equal Time.find_zone!(calendar.time_zone).local(2026, 12, 23, 10, 0), result
  end

  test "preserves local business hours across daylight saving changes" do
    calendar = service_calendar
    start_time = Time.find_zone!(calendar.time_zone).local(2026, 3, 6, 16, 0)

    result = calendar.add_business_minutes(start_time, 120)

    assert_equal Time.find_zone!(calendar.time_zone).local(2026, 3, 9, 10, 0), result
    assert_equal 14, result.utc.hour
  end

  test "counts only overlapping business minutes" do
    calendar = service_calendar
    zone = Time.find_zone!(calendar.time_zone)

    assert_equal 120, calendar.business_minutes_between(
      zone.local(2026, 12, 21, 16, 0),
      zone.local(2026, 12, 22, 10, 0)
    )
  end

  test "rejects negative duration" do
    assert_raises(ArgumentError) { service_calendar.add_business_minutes(Time.current, -1) }
  end

  test "rejects unknown zones and malformed hours" do
    calendar = service_calendar
    calendar.time_zone = "Mars/Olympus"
    calendar.weekly_hours = { "monday" => [ [ "17:00", "09:00" ] ] }

    assert_not calendar.valid?
    assert_includes calendar.errors[:time_zone], "is not recognized"
    assert_includes calendar.errors[:weekly_hours], "contains an invalid interval"
  end

  test "rejects empty, overlapping, and non-string hours" do
    calendar = service_calendar

    calendar.weekly_hours = {}
    assert_not calendar.valid?
    assert_includes calendar.errors[:weekly_hours], "must contain business hours"

    calendar.weekly_hours = { "monday" => [ [ "09:00", "12:00" ], [ "11:00", "17:00" ] ] }
    assert_not calendar.valid?
    assert_includes calendar.errors[:weekly_hours], "contains an invalid interval"

    calendar.weekly_hours = { "monday" => [ [ 900, "17:00" ] ] }
    assert_not calendar.valid?
    assert_includes calendar.errors[:weekly_hours], "contains an invalid interval"
  end

  private
    def service_calendar
      ServiceCalendar.create!(
        workspace: workspaces(:acme_support),
        name: "US support",
        time_zone: "America/New_York",
        weekly_hours: %w[monday tuesday wednesday thursday friday].index_with { [ [ "09:00", "17:00" ] ] }
      )
    end
end
