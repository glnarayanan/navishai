class CalibrationJudgeRunJob < ApplicationJob
  queue_as :evaluations
  self.enqueue_after_transaction_commit = true

  def perform(id)
    run = CalibrationJudgeRun.find_by(id:)
    return unless run
    claimed = run.corpus.with_lock do
      run.lock!
      next false unless run.state == "queued"
      run.update!(state: "running", started_at: Time.current)
      authorize!(run)
      true
    end
    return unless claimed
    sample = run.calibration_sample
    result = JudgeGrader.call(check: sample.eval_case_check, output: sample.output, request_key: run.request_key)
    run.corpus.with_lock do
      return unless authorize!(run)
      sample.create_calibration_prediction!(workspace: run.workspace, corpus: run.corpus, result:, processing_version: JudgeGrader::VERSION, created_at: Time.current)
      run.update!(state: "complete", finished_at: Time.current)
      AuditEvent.record!(action: "calibration.judge_completed", source: :job, workspace: run.workspace, actor_kind: "system", subject: run)
    end
  rescue StandardError => error
    Rails.logger.error("Calibration judge #{id} interrupted (#{error.class})")
    CalibrationJudgeRun.where(id:, state: %w[queued running]).update_all(state: "interrupted", finished_at: Time.current,
      error: "Execution stopped. Access, source evidence or worker state changed. This attempt will not retry; use a new calibration set for another attempt.")
  end

  private
    def authorize!(run)
      run.reload
      return false unless run.state == "running"
      membership = run.workspace.memberships.find_by!(user: run.requested_by)
      run.corpus.authorize_writer!(membership)
      run.calibration_sample.eval_case_check.eval_case.eligible!
      JudgeGrader.authorize!(run.calibration_sample.grader_version)
      true
    end
end
