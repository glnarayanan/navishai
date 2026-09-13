class HealthScorecardProposalWorkflow
  class InvalidCommand < StandardError; end

  PROMPT_RANGE = 10..2_000
  TITLE = "Propose a health scorecard configuration"
  ROLE_KEY = "success_strategist"

  def self.generate!(workspace:, membership:, prompt:, admit: true, client: nil)
    new(workspace:, membership:).generate!(prompt:, admit:, client:)
  end

  def self.accept!(workspace:, membership:, proposal:)
    new(workspace:, membership:).accept!(proposal:)
  end

  def initialize(workspace:, membership:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
  end

  def generate!(prompt:, admit: true, client: nil)
    authorize_write!
    prompt = prompt.to_s.strip
    raise InvalidCommand, "Describe the outcome this scorecard should track." unless prompt.bytesize.in?(PROMPT_RANGE)
    if HealthScorecardProposalPublisher::FORBIDDEN_TEXT.match?(prompt)
      raise InvalidCommand, "Describe the outcome in plain language. Do not include SQL, code, or extra commands."
    end

    scorecard = HealthScorecardDesigner.install_default!(workspace: @workspace)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
    profile = @workspace.agent_profiles.find_by!(role_key: ROLE_KEY)
    RuntimeRouter.resolve!(workspace: @workspace, profile_version: profile.current_version)

    context = HealthScorecardProposalInput.build(workspace: @workspace, scorecard:, prompt:)
    task = CrewWork.create!(
      workspace: @workspace, membership: @membership, scope: scorecard, profile:,
      title: TITLE, input_context: context, expected_output: HealthScorecardProposalInput::EXPECTED_OUTPUT
    )
    ledger = ExecutionLedger.new(workspace: @workspace)
    run = ledger.prepare!(
      task:, request_key: "scorecard-proposal:#{SecureRandom.uuid}", membership: @membership
    )
    ledger.admit!(run:, client:) if admit
    run
  rescue RuntimeRouter::NoCompatibleRuntime, ExecutionLedger::InvalidRun, RunnerClient::Error => error
    raise InvalidCommand, error.message
  rescue CrewWork::InvalidCommand => error
    raise InvalidCommand, error.message
  end

  def accept!(proposal:)
    authorize_write!
    proposal = @workspace.health_scorecard_proposals.find(proposal.id)
    raise InvalidCommand, "Only a valid proposal can become an unpublished scorecard version." unless proposal.acceptable?

    HealthScorecardDesigner.propose!(
      workspace: @workspace, membership: @membership, prompt: proposal.prompt,
      definition: proposal.proposed_definition, explanation: proposal.explanation,
      source_proposal: proposal
    )
  end

  private
    def authorize_write!
      raise Current::RoleAccessDenied unless @membership.can_write?
    end
end
