class CalibrationPrediction < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :calibration_sample
end
