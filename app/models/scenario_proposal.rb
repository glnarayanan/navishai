class ScenarioProposal < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :scenario_version
  belongs_to :requested_by, class_name: "User"
  has_one :scenario_proposal_result
  attr_readonly :workspace_id, :corpus_id, :scenario_version_id, :requested_by_id, :configuration, :input, :processing_version, :request_key, :created_at
  validates :state, inclusion: { in: %w[queued running complete interrupted] }

  def self.request!(version:, membership:, configuration:, disclose: false)
    version.corpus.with_lock do
      version.corpus.authorize_writer!(membership)
      version.scenario.reload
      raise Scenario::Invalid, "Reload the current, active scenario version before requesting a proposal." unless version.scenario.current_version_id == version.id && !version.scenario.merged_into_id
      raise Scenario::Invalid, "Confirm disclosure of this version's starting context and exact evidence before requesting a model proposal." unless disclose == true
      raise Scenario::Invalid, "Use model configuration with endpoint, model and fixed settings; credentials belong in the operator registry." unless ModelGateway.valid_configuration?(configuration)
      input = ScenarioExtractor.input(version)
      EvaluationHttp.validate!({ "endpoint" => configuration.fetch("endpoint") }, workspace_id: version.workspace_id, purpose: :scenario)
      existing = find_by(scenario_version: version)
      return existing if existing
      proposal = create!(workspace: version.workspace, corpus: version.corpus, scenario_version: version, requested_by: membership.user,
        configuration:, input:, processing_version: ScenarioExtractor::VERSION, created_at: Time.current)
      AuditEvent.record!(action: "scenario.proposal_requested", source: :web, workspace: version.workspace, actor: membership.user, subject: proposal)
      ScenarioProposalJob.perform_later(proposal.id)
      proposal
    end
  end

  def interrupt!(membership:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      lock!
      raise Scenario::Invalid, "Only a queued proposal or one started over ten minutes ago can be interrupted." unless state == "queued" || (state == "running" && started_at < 10.minutes.ago)
      update!(state: "interrupted", finished_at: Time.current, error: "Expert interrupted this attempt. It will not retry; revise the scenario before another attempt.")
      AuditEvent.record!(action: "scenario.proposal_interrupted", source: :web, workspace:, actor: membership.user, subject: self)
    end
  end
end
