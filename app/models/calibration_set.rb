class CalibrationSet < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :grader_version
  belongs_to :created_by, class_name: "User"
  has_many :calibration_samples
  validates :name, presence: true, length: { maximum: 120 }

  def self.define!(corpus:, membership:, name:, grader_version_id:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      raise EvalCase::Invalid, "Source retention ended. Wait for source purge before calibration." if corpus.eval_definitions_expired?
      version = corpus.grader_versions.find(grader_version_id)
      set = create!(workspace: corpus.workspace, corpus:, grader_version: version, created_by: membership.user, name:, created_at: Time.current)
      AuditEvent.record!(action: "calibration.created", source: :web, workspace: corpus.workspace, actor: membership.user, subject: set)
      set
    end
  end

  def add_sample!(membership:, check_id:, cohort:, output: nil, evaluation_result_id: nil)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      check = EvalCaseCheck.where(corpus:, grader_version:).find(check_id)
      check.eval_case.eligible!
      result = EvaluationResult.where(corpus:).find(evaluation_result_id) if evaluation_result_id.present?
      if result
        raise EvalCase::Invalid, "Choose a check from this result's fixed case and grader version." unless result.eval_case_id == check.eval_case_id
        raise EvalCase::Invalid, "This result has no usable output. Choose another retained result." if result.status == "error" || result.output.nil?
        output = result.output
      end
      SupportOutput.validate!(output)
      digest = Digest::SHA256.hexdigest(output.to_json)
      existing = calibration_samples.find_by(eval_case_check: check, output:)
      if existing
        raise EvalCase::Invalid, "This exact output already has different provenance (sample ##{existing.id}). Review that sample or choose another output; provenance cannot be replaced." unless existing.evaluation_result_id == result&.id
        raise EvalCase::Invalid, "This output already belongs to #{existing.cohort.humanize.downcase}; samples cannot change cohorts." unless existing.cohort == cohort
        return existing
      end
      raise EvalCase::Invalid, "A calibration set holds at most 100 samples." if calibration_samples.count >= 100
      sample = calibration_samples.create!(workspace:, corpus:, grader_version:, eval_case_check: check, eval_case: check.eval_case, evaluation_result: result, created_by: membership.user, cohort:, output_digest: digest, output:, created_at: Time.current)
      if grader_version.kind == "deterministic"
        result = DeterministicGrader.call(definition: grader_version.definition, output:, knowledge: check.eval_case.scenario_version.target_input.fetch("knowledge"))
        sample.create_calibration_prediction!(workspace:, corpus:, result:, processing_version: grader_version.processing_version, created_at: Time.current)
      end
      AuditEvent.record!(action: "calibration.sample_added", source: :web, workspace:, actor: membership.user, subject: sample)
      sample
    end
  end
end
