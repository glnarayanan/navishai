class EvaluationRunJob < ApplicationJob
  queue_as :evaluations
  self.enqueue_after_transaction_commit = true

  def perform(id)
    run = EvaluationRun.find_by(id:)
    return unless run
    claimed = run.corpus.with_lock do
      run.lock!
      next false unless run.state == "queued"
      run.update!(state: "running", started_at: Time.current)
      true
    end
    return unless claimed

    raise EvalCase::Invalid, "Run processing version is not available." unless run.processing_version == EvaluationRun::VERSION
    run.evaluation_run_items.order(:id).each do |item|
      run.corpus.with_lock do
        run.reload
        return unless run.state == "running"
        membership = run.workspace.memberships.find_by!(user: run.requested_by)
        run.corpus.authorize_writer!(membership)
        item.eval_case.eligible!
        begin
          output = run.evaluation_target_version.call(input: item.target_input)
          SupportOutput.validate!(output)
          decisions = item.eval_case.eval_case_checks.order(:id).map do |check|
            result = if check.grader_version.kind == "deterministic"
              DeterministicGrader.call(definition: check.grader_version.definition, output:, knowledge: item.target_input.fetch("knowledge"))
            else
              { "decision" => "abstain", "reason" => "No judge configured. A rubric alone is not an executed judgment.", "confidence" => nil }
            end
            result.merge("check_id" => check.id, "grader_version_id" => check.grader_version_id)
          end
          status = decisions.any? { |decision| decision["decision"] == "fail" } ? "fail" : decisions.all? { |decision| decision["decision"] == "pass" } ? "pass" : "incomplete"
          item.create_evaluation_result!(workspace: run.workspace, corpus: run.corpus, eval_case: item.eval_case, output:, decisions:, status:, created_at: Time.current)
        rescue SupportOutput::Invalid
          item.create_evaluation_result!(workspace: run.workspace, corpus: run.corpus, eval_case: item.eval_case, status: "error", created_at: Time.current,
            error: "Target/check output did not match the versioned schema. This is an execution error, not a support failure.")
        end
      end
    end
    run.corpus.with_lock do
      run.reload
      if run.state == "running"
        run.update!(state: "complete", finished_at: Time.current)
        AuditEvent.record!(action: "evaluation.completed", source: :job, workspace: run.workspace, actor_kind: "system", subject: run)
      end
    end
  rescue StandardError => error
    Rails.logger.error("Evaluation run #{id} interrupted (#{error.class})")
    EvaluationRun.where(id:, state: "running").update_all(state: "interrupted", finished_at: Time.current,
      error: "Execution stopped. Access, source evidence or worker state changed. Prior results remain; this run will not retry.")
  end
end
