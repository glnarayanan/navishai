class UsageCostCapture
  UNITS_PER_RATE = 1_000_000

  def self.capture_run!(workspace:, run:)
    run = workspace.execution_runs.find(run.id)
    return run.usage_cost_snapshot if run.usage_cost_snapshot

    usage = run.events.where(event_type: "usage.observed").order(:sequence_number).pluck(:data)
    attributes = run_attributes(run, usage)
    workspace.usage_cost_snapshots.create!(attributes.merge(execution_run: run, captured_at: run.finished_at || Time.current))
  rescue ActiveRecord::RecordNotUnique
    run.reload_usage_cost_snapshot
  end

  def self.capture_search!(workspace:, search:)
    search = workspace.public_web_searches.find(search.id)
    return search.usage_cost_snapshot if search.usage_cost_snapshot

    attributes = search_attributes(search)
    workspace.usage_cost_snapshots.create!(attributes.merge(public_web_search: search, captured_at: search.retrieved_at || Time.current))
  rescue ActiveRecord::RecordNotUnique
    search.reload_usage_cost_snapshot
  end

  def self.run_attributes(run, usage)
    return unknown("execution_ledger", "usage_not_reported") if usage.empty?

    observed = { observed_input_units: run.input_units, observed_output_units: run.output_units }
    reported_amounts = usage.filter_map { |event| event["amount_micros"] }
    if reported_amounts.any?
      currency = usage.filter_map { |event| event["currency"] }.uniq.sole
      status = reported_amounts.size == usage.size ? "complete" : "partial"
      amount_micros = reported_amounts.sum
      if amount_micros > RunnerProtocol::BIGINT_MAX
        return unknown("execution_events", "reported_amount_out_of_range").merge(observed)
      end
      return observed.merge(
        status:, source: "adapter_reported", currency:, amount_micros:,
        calculation_provenance: {
          "source" => "execution_events", "adapter_key" => run.selected_adapter_key,
          "usage_event_count" => usage.size,
          "reported_amount_event_count" => reported_amounts.size,
          "calculation" => "sum_adapter_reported_micros"
        }
      )
    end

    configured_attributes(
      version: run.usage_rate_version,
      components: {
        "input" => [ run.input_units, run.usage_rate_version&.input_rate_micros_per_million ],
        "output" => [ run.output_units, run.usage_rate_version&.output_rate_micros_per_million ]
      }
    ).merge(observed)
  rescue ArgumentError
    unknown("execution_events", "reported_currency_conflict").merge(observed)
  end
  private_class_method :run_attributes

  def self.search_attributes(search)
    return unknown("search_ledger", "cost_units_not_reported") unless search.completed?

    configured_attributes(
      version: search.usage_rate_version,
      components: {
        "search" => [ search.cost_units, search.usage_rate_version&.search_rate_micros_per_million ]
      }
    ).merge(observed_search_units: search.cost_units)
  end
  private_class_method :search_attributes

  def self.configured_attributes(version:, components:)
    return unknown("configured_rate", "no_rate_frozen") unless version

    missing = components.filter_map { |name, (units, rate)| name if units.positive? && rate.nil? }
    known = components.filter_map do |name, (units, rate)|
      next if rate.nil?

      [ name, { "units" => units, "rate_micros_per_million" => rate } ]
    end.to_h
    return unknown("configured_rate", "required_rate_unavailable") if known.empty?

    amount = known.sum { |_name, values| Rational(values.fetch("units") * values.fetch("rate_micros_per_million"), UNITS_PER_RATE) }.round
    return unknown("configured_rate", "calculated_amount_out_of_range") if amount > RunnerProtocol::BIGINT_MAX

    {
      status: missing.empty? ? "complete" : "partial",
      source: "configured_rate", currency: version.currency, amount_micros: amount,
      applied_usage_rate_version: version,
      calculation_provenance: {
        "source" => version.source_name, "rate_version" => version.version_number,
        "components" => known, "missing_components" => missing,
        "calculation" => "round_half_up(sum(units*rate_micros_per_million/1000000))"
      }
    }
  end
  private_class_method :configured_attributes

  def self.unknown(source, reason)
    {
      status: reason.end_with?("not_reported") ? "not_reported" : "unavailable",
      calculation_provenance: { "source" => source, "reason" => reason }
    }
  end
  private_class_method :unknown
end
