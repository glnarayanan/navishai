module HealthScorecardsHelper
  def scorecard_proposal_diff_items(diff)
    rules = Array(diff&.fetch("rules", nil))
    changed = rules.reject { |rule| rule.fetch("kind") == "unchanged" }
    bands = []
    %w[healthy_min watch_min].each do |key|
      from_value, to_value = Array(diff&.fetch(key, nil))
      next if from_value == to_value

      bands << { "label" => key.humanize, "from_weight" => from_value, "to_weight" => to_value, "kind" => "changed" }
    end
    bands + changed
  end

  def scorecard_diff_value(value)
    value.nil? ? "none" : value.to_s
  end
end
