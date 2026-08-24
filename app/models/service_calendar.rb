class ServiceCalendar < ApplicationRecord
  DAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

  belongs_to :workspace
  has_many :holidays, class_name: "ServiceCalendarHoliday", dependent: :restrict_with_exception
  has_many :sla_policies, dependent: :restrict_with_exception

  normalizes :name, with: ->(name) { name.strip }
  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { scope: :workspace_id }
  validate :time_zone_exists
  validate :weekly_hours_are_valid

  def add_business_minutes(start_time, minutes)
    add_business_seconds(start_time, Integer(minutes) * 60)
  end

  def add_business_seconds(start_time, seconds)
    remaining_seconds = Integer(seconds)
    raise ArgumentError, "duration must not be negative" if remaining_seconds.negative?

    cursor = start_time
    return cursor if remaining_seconds.zero?

    each_interval_from(cursor) do |interval_start, interval_end|
      available_start = [ cursor, interval_start ].max
      available_seconds = interval_end - available_start
      return available_start + remaining_seconds if available_seconds >= remaining_seconds

      remaining_seconds -= available_seconds
      cursor = interval_end
    end
  end

  def business_minutes_between(from, to)
    (business_seconds_between(from, to) / 60).floor
  end

  def business_seconds_between(from, to)
    return 0 if to <= from

    seconds = 0
    each_interval_from(from, through: to) do |interval_start, interval_end|
      overlap_start = [ from, interval_start ].max
      overlap_end = [ to, interval_end ].min
      seconds += overlap_end - overlap_start if overlap_end > overlap_start
    end
    seconds.to_i
  end

  private
    def each_interval_from(start_time, through: nil)
      zone = ActiveSupport::TimeZone[time_zone]
      date = start_time.in_time_zone(zone).to_date
      holiday_dates = holidays.where(date: date..(through&.in_time_zone(zone)&.to_date || date + 10.years)).pluck(:date).to_set

      loop do
        break if through && date > through.in_time_zone(zone).to_date

        unless holiday_dates.include?(date)
          intervals_for(date).each do |from_text, to_text|
            interval_start = local_time(zone, date, from_text)
            interval_end = local_time(zone, date, to_text)
            yield interval_start, interval_end if interval_end > start_time && (!through || interval_start < through)
          end
        end
        date += 1.day
        raise RangeError, "business-time target exceeds ten years" if date > start_time.in_time_zone(zone).to_date + 10.years
      end
    end

    def intervals_for(date)
      weekly_hours.fetch(DAYS.fetch(date.wday), [])
    end

    def local_time(zone, date, text)
      hour, minute = text.split(":").map(&:to_i)
      zone.local(date.year, date.month, date.day, hour, minute)
    end

    def time_zone_exists
      errors.add(:time_zone, "is not recognized") unless ActiveSupport::TimeZone[time_zone]
    end

    def weekly_hours_are_valid
      unless weekly_hours.is_a?(Hash) && (weekly_hours.keys - DAYS).empty?
        errors.add(:weekly_hours, "must use weekday keys")
        return
      end
      errors.add(:weekly_hours, "must contain business hours") if weekly_hours.values.flatten(1).empty?

      weekly_hours.each_value do |intervals|
        valid = intervals.is_a?(Array) && intervals.all? do |interval|
          interval.is_a?(Array) && interval.length == 2 && interval.all? { |value| value.is_a?(String) && value.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/) } && interval.first < interval.last
        end
        valid &&= intervals.each_cons(2).all? { |left, right| left.last <= right.first }
        errors.add(:weekly_hours, "contains an invalid interval") unless valid
      end
    end
end
