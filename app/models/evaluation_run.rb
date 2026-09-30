class EvaluationRun < ApplicationRecord
  VERSION = "support-evaluation-v1"
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :eval_suite
  belongs_to :evaluation_target_version
  belongs_to :requested_by, class_name: "User"
  has_many :evaluation_run_items
  has_many :evaluation_results, through: :evaluation_run_items
  attr_readonly :workspace_id, :corpus_id, :eval_suite_id, :evaluation_target_version_id, :requested_by_id, :processing_version, :judge_disclosure, :created_at
  validates :state, inclusion: { in: %w[queued running complete interrupted] }

  def self.request!(suite:, membership:, target_version_id:, disclose: false, judge_disclose: false, suite_digest: nil)
    suite.corpus.with_lock do
      corpus = suite.corpus
      corpus.authorize_writer!(membership)
      target = EvaluationTargetVersion.where(corpus:).find(target_version_id)
      if target.adapter == "http"
        raise EvalCase::Invalid, "Run not started. Confirm disclosure of visible case context and permitted knowledge before starting an HTTP run." unless disclose == true
        HttpTarget.validate!(target.configuration, workspace_id: corpus.workspace_id)
      end
      items = suite.eval_cases.order(:id).to_a
      raise EvalCase::Invalid, "Run a suite with 1–50 cases and at most 100 checks." unless items.size.between?(1, 50) && items.sum { |item| item.eval_case_checks.count } <= 100
      items.each(&:eligible!)
      judges = items.flat_map { |item| item.eval_case_checks.includes(:grader_version).map(&:grader_version) }.select { |version| version.kind == "rubric_judge" && version.definition.key?("execution") }.uniq(&:id)
      if judges.any?
        raise EvalCase::Invalid, "Run not started. Separately confirm disclosure of outputs, rubrics, context and company evidence to the fixed judges." unless judge_disclose == true
        judges.each { |version| JudgeGrader.authorize!(version) }
      end
      if target.adapter == "http" || judges.any?
        raise EvalCase::Invalid, "Run not started. Suite membership changed or its consent token is missing. Reload and review the cases and endpoints before confirming again." unless suite_digest == Digest::SHA256.hexdigest(items.map(&:id).to_json)
      end
      run = corpus.evaluation_runs.create!(workspace: corpus.workspace, eval_suite: suite, evaluation_target_version: target, requested_by: membership.user, processing_version: VERSION, judge_disclosure: judge_disclose == true, created_at: Time.current)
      items.each { |item| run.evaluation_run_items.create!(workspace: corpus.workspace, corpus:, eval_case: item, target_input: item.scenario_version.target_input) }
      AuditEvent.record!(action: "evaluation.requested", source: :web, workspace: corpus.workspace, actor: membership.user, subject: run)
      EvaluationRunJob.perform_later(run.id)
      run
    end
  end

  def interrupt!(membership:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      lock!
      raise EvalCase::Invalid, "Only a queued run or a run started over ten minutes ago can be interrupted." unless state == "queued" || (state == "running" && started_at < 10.minutes.ago)
      update!(state: "interrupted", finished_at: Time.current, error: "Expert interrupted this run. It will not retry; start a separate run deliberately.")
      AuditEvent.record!(action: "evaluation.interrupted", source: :web, workspace:, actor: membership.user, subject: self)
    end
  end
end
