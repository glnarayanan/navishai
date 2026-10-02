class CalibrationReport
  def self.call(set:, cohort: "held_out")
    samples = set.calibration_samples.where(cohort:).includes(:calibration_prediction).order(:id)
    counts = { samples: samples.size, labelled: 0, disputed: 0, uncertain: 0, unpredicted: 0, abstained: 0,
      true_positive: 0, false_positive: 0, false_negative: 0, true_negative: 0, compared: 0, pairs: 0, agreeing_pairs: 0 }
    samples.each do |sample|
      labels = sample.latest_labels.pluck(:decision)
      counts[:labelled] += 1 if labels.any?
      labels.select { |label| %w[pass fail].include?(label) }.combination(2) do |a, b|
        counts[:pairs] += 1
        counts[:agreeing_pairs] += 1 if a == b
      end
      if labels.include?("pass") && labels.include?("fail")
        counts[:disputed] += 1
        next
      end
      if labels.include?("uncertain")
        counts[:uncertain] += 1
        next
      end
      next if labels.empty?

      prediction = sample.calibration_prediction&.result&.fetch("decision")
      unless %w[pass fail].include?(prediction)
        counts[prediction == "abstain" ? :abstained : :unpredicted] += 1
        next
      end
      counts[:compared] += 1
      key = { [ "fail", "fail" ] => :true_positive, [ "fail", "pass" ] => :false_positive,
        [ "pass", "fail" ] => :false_negative, [ "pass", "pass" ] => :true_negative }.fetch([ prediction, labels.first ])
      counts[key] += 1
    end
    ratio = ->(numerator, denominator) { denominator.zero? ? nil : numerator.fdiv(denominator) }
    counts.merge(precision: ratio.call(counts[:true_positive], counts[:true_positive] + counts[:false_positive]),
      recall: ratio.call(counts[:true_positive], counts[:true_positive] + counts[:false_negative]),
      disagreement_rate: ratio.call(counts[:false_positive] + counts[:false_negative], counts[:compared]),
      inter_rater_agreement: ratio.call(counts[:agreeing_pairs], counts[:pairs]))
  end
end
