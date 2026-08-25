class HealthScorecardDefinition
  class InvalidDefinition < StandardError; end

  CATALOG = {
    "open_cases" => {
      label: "Open support cases", detail: "Adds 5 risk points per open case.",
      value_kind: "number", default_weight: 20, strategy: "per_unit", rate: 5, base_weight: 20
    },
    "sla_breaches" => {
      label: "SLA breaches", detail: "Adds 10 risk points per breached case clock.",
      value_kind: "number", default_weight: 25, strategy: "per_unit", rate: 10, base_weight: 25
    },
    "customer_inactivity_days" => {
      label: "Customer inactivity", detail: "Adds risk after 14, 30, and 60 days without an inbound message.",
      value_kind: "number", default_weight: 20, strategy: "thresholds", base_weight: 20,
      thresholds: [ [ 14, 5 ], [ 30, 12 ], [ 60, 20 ] ]
    },
    "renewal_on" => {
      label: "Renewal proximity", detail: "Adds risk inside 180, 90, and 30 days before renewal.",
      value_kind: "date", default_weight: 25, strategy: "within_days", base_weight: 25,
      thresholds: [ [ 180, 5 ], [ 90, 15 ], [ 30, 25 ] ]
    },
    "seat_utilization_percent" => {
      label: "Seat use", detail: "Adds risk below 60% and 30% active-seat use.",
      value_kind: "number", default_weight: 15, strategy: "below", base_weight: 15,
      thresholds: [ [ 60, 8 ], [ 30, 15 ] ]
    }
  }.freeze
  CONTEXT_KEYS = %w[internal_notes_90d contract_value].freeze
  DEFAULT_PROMPT = "Use the NavishAI starting scorecard."

  def self.default
    build(healthy_min: 75, watch_min: 50,
      weights: CATALOG.transform_values { |entry| entry.fetch(:default_weight) })
  end

  def self.build(healthy_min:, watch_min:, weights:)
    healthy = strict_integer(healthy_min, "Healthy threshold")
    watch = strict_integer(watch_min, "Watch threshold")
    values = weights.to_h.stringify_keys
    rules = CATALOG.filter_map do |key, entry|
      next unless values.key?(key)
      weight = strict_integer(values.fetch(key), entry.fetch(:label))
      next if weight.zero?
      raise InvalidDefinition, "#{entry.fetch(:label)} weight must be between 0 and 100." unless weight.in?(0..100)
      { "signal_key" => key, "weight" => weight }
    end
    definition = { "schema_version" => 1, "healthy_min" => healthy, "watch_min" => watch, "rules" => rules }
    validate!(definition)
    definition
  end

  def self.validate!(definition)
    unless definition.is_a?(Hash) && definition.keys.sort == %w[healthy_min rules schema_version watch_min] &&
        definition["schema_version"] == 1 && definition["healthy_min"].is_a?(Integer) &&
        definition["watch_min"].is_a?(Integer) && definition["rules"].is_a?(Array)
      raise InvalidDefinition, "does not match the scorecard schema"
    end
    unless definition["watch_min"].in?(1..98) &&
        definition["healthy_min"].in?((definition["watch_min"] + 1)..99)
      raise InvalidDefinition, "bands must satisfy 1 ≤ watch < healthy ≤ 99"
    end
    keys = definition["rules"].map do |rule|
      unless rule.is_a?(Hash) && rule.keys.sort == %w[signal_key weight] &&
          CATALOG.key?(rule["signal_key"]) && rule["weight"].is_a?(Integer) && rule["weight"].in?(1..100)
        raise InvalidDefinition, "contains an unsupported signal rule"
      end
      rule["signal_key"]
    end
    raise InvalidDefinition, "must map at least one signal" if keys.empty?
    raise InvalidDefinition, "cannot map a signal twice" unless keys.uniq.size == keys.size
    raise InvalidDefinition, "total signal weight cannot exceed 200" if definition["rules"].sum { |rule| rule["weight"] } > 200
    true
  end

  def self.score(signals:, definition:, calculated_at:)
    validate!(definition)
    values = signals.index_by { |signal| signal.respond_to?(:signal_key) ? signal.signal_key : signal.fetch("signal_key") }
    points = definition.fetch("rules").sum do |rule|
      signal = values[rule.fetch("signal_key")]
      signal ? risk_points(signal, rule.fetch("signal_key"), rule.fetch("weight"), calculated_at) : 0
    end
    score = [ 100 - points, 0 ].max
    level = score >= definition.fetch("healthy_min") ? "healthy" :
      score >= definition.fetch("watch_min") ? "watch" : "at_risk"
    { score:, risk_level: level }
  end

  def self.apply(signals:, definition:, calculated_at:)
    weights = definition.fetch("rules").to_h { |rule| [ rule.fetch("signal_key"), rule.fetch("weight") ] }
    signals.map do |signal|
      weight = weights.fetch(signal.signal_key, 0)
      signal.with(weight:, risk_points: weight.zero? ? 0 : risk_points(signal, signal.signal_key, weight, calculated_at))
    end
  end

  def self.risk_points(signal, key, weight, calculated_at)
    entry = CATALOG.fetch(key)
    value = value_for(signal, entry.fetch(:value_kind))
    base = case entry.fetch(:strategy)
    when "per_unit"
      [ value.to_d * entry.fetch(:rate), entry.fetch(:base_weight) ].min
    when "thresholds"
      entry.fetch(:thresholds).select { |threshold, _| value.to_d >= threshold }.last&.last.to_i
    when "within_days"
      days = (Date.iso8601(value.to_s) - calculated_at.to_date).to_i
      entry.fetch(:thresholds).select { |threshold, _| days <= threshold }.last&.last.to_i
    when "below"
      entry.fetch(:thresholds).select { |threshold, _| value.to_d < threshold }.last&.last.to_i
    end
    [ (base.to_d * weight / entry.fetch(:base_weight)).round, weight ].min.to_i
  end
  private_class_method :risk_points

  def self.value_for(signal, kind)
    if signal.respond_to?(:numeric_value)
      kind == "date" ? signal.date_value : signal.numeric_value
    else
      signal.fetch(kind == "date" ? "date_value" : "numeric_value")
    end
  end
  private_class_method :value_for

  def self.strict_integer(value, label)
    Integer(value.to_s, 10)
  rescue ArgumentError, TypeError
    raise InvalidDefinition, "#{label} must be a whole number."
  end
  private_class_method :strict_integer
end
