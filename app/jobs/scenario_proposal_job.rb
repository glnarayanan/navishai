class ScenarioProposalJob < ApplicationJob
  queue_as :evaluations
  self.enqueue_after_transaction_commit = true

  def perform(id)
    proposal = ScenarioProposal.find_by(id:)
    return unless proposal
    claimed = proposal.corpus.with_lock do
      proposal.lock!
      next false unless proposal.state == "queued"
      proposal.update!(state: "running", started_at: Time.current)
      authorize!(proposal)
      true
    end
    return unless claimed
    result = ScenarioExtractor.call(proposal)
    proposal.corpus.with_lock do
      return unless authorize!(proposal)
      proposal.create_scenario_proposal_result!(workspace: proposal.workspace, corpus: proposal.corpus, result:, created_at: Time.current)
      proposal.update!(state: "complete", finished_at: Time.current)
      AuditEvent.record!(action: "scenario.proposal_completed", source: :job, workspace: proposal.workspace, actor_kind: "system", subject: proposal)
    end
  rescue StandardError => error
    Rails.logger.error("Scenario proposal #{id} interrupted (#{error.class})")
    ScenarioProposal.where(id:, state: %w[queued running]).update_all(state: "interrupted", finished_at: Time.current,
      error: "Execution stopped. Access, source evidence or worker state changed. This attempt will not retry; revise the scenario before another attempt.")
  end

  private
    def authorize!(proposal)
      proposal.reload
      return false unless proposal.state == "running"
      raise Scenario::Invalid, "Unsupported proposal protocol or settings." unless proposal.processing_version == ScenarioExtractor::VERSION && ModelGateway.valid_configuration?(proposal.configuration)
      membership = proposal.workspace.memberships.find_by!(user: proposal.requested_by)
      proposal.corpus.authorize_writer!(membership)
      ScenarioExtractor.input(proposal.scenario_version)
      raise Scenario::Invalid, "Scenario merged." if proposal.scenario_version.scenario.reload.merged_into_id
      EvaluationHttp.validate!(proposal.configuration.slice("endpoint"), workspace_id: proposal.workspace_id, purpose: :scenario)
      true
    end
end
