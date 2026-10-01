class CalibrationReport
  REVIEW_STATES = { "unlabelled" => "Needs your label", "disputed" => "Experts disagree", "uncertain" => "Expert uncertainty",
    "disagreement" => "Machine / expert disagreement", "uncompared" => "No usable prediction", "aligned" => "Machine / experts agree" }.freeze

  def self.call(set:, cohort: "held_out", reviewer: nil)
    samples = set.calibration_samples.where(cohort:).includes(:calibration_prediction).order(:id)
    reviews = []
    counts = { samples: samples.size, labelled: 0, disputed: 0, uncertain: 0, unpredicted: 0, abstained: 0,
      true_positive: 0, false_positive: 0, false_negative: 0, true_negative: 0, compared: 0, pairs: 0, agreeing_pairs: 0 }
    samples.each do |sample|
      latest = sample.latest_labels.to_a
      labels = latest.map(&:decision)
      prediction = sample.calibration_prediction&.result&.fetch("decision")
      state = if labels.empty?
        "unlabelled"
      elsif labels.include?("pass") && labels.include?("fail")
        "disputed"
      elsif labels.include?("uncertain")
        "uncertain"
      elsif !%w[pass fail].include?(prediction)
        "uncompared"
      elsif prediction == labels.first
        "aligned"
      else
        "disagreement"
      end
      personal_state = reviewer && latest.none? { |label| label.labelled_by_id == reviewer.id } ? "unlabelled" : state
      reviews << { sample:, state: personal_state, label_count: latest.size }
      counts[:labelled] += 1 if labels.any?
      labels.select { |label| %w[pass fail].include?(label) }.combination(2) do |a, b|
        counts[:pairs] += 1
        counts[:agreeing_pairs] += 1 if a == b
      end
      if state == "disputed"
        counts[:disputed] += 1
        next
      end
      if state == "uncertain"
        counts[:uncertain] += 1
        next
      end
      next if labels.empty?

      if state == "uncompared"
        counts[prediction == "abstain" ? :abstained : :unpredicted] += 1
        next
      end
      counts[:compared] += 1
      key = { [ "fail", "fail" ] => :true_positive, [ "fail", "pass" ] => :false_positive,
        [ "pass", "fail" ] => :false_negative, [ "pass", "pass" ] => :true_negative }.fetch([ prediction, labels.first ])
      counts[key] += 1
    end
    ratio = ->(numerator, denominator) { denominator.zero? ? nil : numerator.fdiv(denominator) }
    counts.merge(reviews:, precision: ratio.call(counts[:true_positive], counts[:true_positive] + counts[:false_positive]),
      recall: ratio.call(counts[:true_positive], counts[:true_positive] + counts[:false_negative]),
      disagreement_rate: ratio.call(counts[:false_positive] + counts[:false_negative], counts[:compared]),
      inter_rater_agreement: ratio.call(counts[:agreeing_pairs], counts[:pairs]))
  end
end
