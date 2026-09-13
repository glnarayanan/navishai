class HealthScorecardProposalDiff
  Change = Data.define(:signal_key, :label, :from_weight, :to_weight, :kind)

  def self.between(from_definition, to_definition)
    from_rules = index(from_definition)
    to_rules = index(to_definition)
    rules = (from_rules.keys | to_rules.keys).sort.map do |key|
      from_weight = from_rules[key]
      to_weight = to_rules[key]
      kind = if from_weight.nil?
        "added"
      elsif to_weight.nil?
        "removed"
      elsif from_weight != to_weight
        "changed"
      else
        "unchanged"
      end
      Change.new(
        signal_key: key,
        label: HealthScorecardDefinition::CATALOG.dig(key, :label) || key,
        from_weight:, to_weight:, kind:
      )
    end
    {
      "healthy_min" => [ from_definition&.dig("healthy_min"), to_definition&.dig("healthy_min") ],
      "watch_min" => [ from_definition&.dig("watch_min"), to_definition&.dig("watch_min") ],
      "rules" => rules.map { |change| change.to_h.stringify_keys }
    }
  end

  def self.index(definition)
    Array(definition&.dig("rules")).each_with_object({}) do |rule, indexed|
      next unless rule.is_a?(Hash)

      indexed[rule["signal_key"].to_s] = rule["weight"]
    end
  end
  private_class_method :index
end
