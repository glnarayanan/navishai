class CalibrationJudgeRun < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :calibration_sample
  belongs_to :requested_by, class_name: "User"
  attr_readonly :workspace_id, :corpus_id, :calibration_sample_id, :requested_by_id, :request_key, :created_at
  validates :state, inclusion: { in: %w[queued running complete interrupted] }

  def self.request!(sample:, membership:, disclose: false)
    sample.corpus.with_lock do
      sample.corpus.authorize_writer!(membership)
      sample.eval_case_check.eval_case.eligible!
      raise EvalCase::Invalid, "Confirm disclosure of this sample's output, rubric, context and company evidence before requesting its judge." unless disclose == true
      JudgeGrader.authorize!(sample.grader_version)
      existing = find_by(calibration_sample: sample)
      return existing if existing
      raise EvalCase::Invalid, "A fixed prediction already exists. Use a new calibration set to measure a new attempt." if sample.calibration_prediction
      run = create!(workspace: sample.workspace, corpus: sample.corpus, calibration_sample: sample, requested_by: membership.user, created_at: Time.current)
      AuditEvent.record!(action: "calibration.judge_requested", source: :web, workspace: sample.workspace, actor: membership.user, subject: run)
      CalibrationJudgeRunJob.perform_later(run.id)
      run
    end
  end

  def interrupt!(membership:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      lock!
      raise EvalCase::Invalid, "Only a queued judge or one started over ten minutes ago can be interrupted." unless state == "queued" || (state == "running" && started_at < 10.minutes.ago)
      update!(state: "interrupted", finished_at: Time.current, error: "Expert interrupted this attempt. It will not retry; use a new calibration set for another attempt.")
      AuditEvent.record!(action: "calibration.judge_interrupted", source: :web, workspace:, actor: membership.user, subject: self)
    end
  end
end
