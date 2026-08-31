require_relative "../config/environment"

TaskView = Data.define(
  :workspace, :task_key, :title, :input_context, :expected_output,
  :assigned_agent_profile, :assigned_agent_profile_version
)

secret = ENV.fetch("NAVISHAI_RUNNER_SHARED_SECRET")
address = ENV.fetch("NAVISHAI_RUNNER_ADDRESS")
client = RunnerClient.new(address:, secret:)
abort "runner is not ready for protocol v1" unless client.ready?

providers = ProviderConnectionGateway.new(address:, secret:).catalog(workspace_key: SecureRandom.uuid)
expected_provider_keys = %w[claude_subscription codex_subscription cursor_acp_subscription grok_acp_subscription]
actual_provider_keys = providers.map { |provider| provider.fetch("adapter_key") }.sort
abort "provider catalog was incomplete: #{actual_provider_keys.inspect}" unless actual_provider_keys == expected_provider_keys
abort "provider catalog exposed a configured secret" if providers.any? { |provider| provider.fetch("configured") || provider.fetch("secret_configured") }

suffix = SecureRandom.hex(6)
organization = Organization.create!(name: "Runner Contract #{suffix}", slug: "runner-contract-#{suffix}")
workspace = organization.workspaces.create!(name: "Contract", slug: "contract-#{suffix}")
user = User.create!(email_address: "runner-contract-#{suffix}@example.com", password: SecureRandom.base64(32), verified_at: Time.current)
membership = workspace.memberships.create!(user:, role: :owner)
CrewConfiguration.install_defaults!(workspace:)

reports = client.detect_runtimes!(workspace_key: workspace.runner_key)
report = reports.find { |candidate| candidate.fetch("detection_key") == ENV.fetch("NAVISHAI_RUNNER_CONTRACT_DETECTION_KEY") }
unless report
  detected = reports.map { |candidate| [ candidate.fetch("adapter_key"), candidate.fetch("detection_key") ] }
  abort "scripted runtime was not detected: #{detected.inspect}"
end
RuntimeRegistry.refresh!(workspace:, membership:, client:)
installation = workspace.runtime_installations.find_by!(detection_key: report.fetch("detection_key"))
RuntimeRegistry.test!(workspace:, membership:, installation:, client:)
abort "scripted runtime connection test did not pass" unless installation.reload.runtime_test_status == "passed"
RuntimeRegistry.update_approval!(
  workspace:, membership:, installation:,
  attributes: {
    approved: true, allowed_role_keys: [ "support_coordinator" ],
    allowed_tools: %w[case_read conversation_read],
    allowed_data_classes: %w[case_content customer_identity], profile_keys: [ "workspace_default" ],
    max_timeout_seconds: 900, max_steps: 20, max_tool_calls: 50,
    max_input_units: 100_000, max_output_units: 25_000
  }
)

account = workspace.accounts.create!(name: "Contract Account")
contact = account.contacts.create!(workspace:, name: "Contract Contact")
message = ConversationThread.start_inbound!(
  workspace:, contact:, subject: "Runner contract", body: "Check the scripted execution path.",
  occurred_at: Time.current, source: :integration
)
profile = workspace.agent_profiles.find_by!(role_key: "support_coordinator")
task = CrewWork.create!(
  workspace:, membership:, scope: message.conversation.support_case, profile:,
  title: "Run the contract", input_context: "Use the current case.", expected_output: "Return a bounded result."
)
CrewWork.apply!(
  workspace:, membership:, task:, command: :start, expected_sequence: task.current_event.sequence_number
)
run = ExecutionLedger.start!(workspace:, task:, request_key: "contract:#{suffix}", client:)

deadline = 10.seconds.from_now
until !run.reload.active? || Time.current >= deadline
  sleep 0.05
end
abort "scripted run did not complete: #{run.status} #{run.failure_code}" unless run.completed?
expected_events = %w[run.admitted run.started output.produced usage.observed run.completed]
abort "scripted lifecycle was incomplete: #{run.events.pluck(:event_type).inspect}" unless run.events.pluck(:event_type) == expected_events
abort "scripted output was not retained" unless run.output == "NAVISHAI_RUNTIME_TEST_OK"

first = client.admit!(task:, run:, run_id: run.run_key, idempotency_key: "admit:#{run.run_key}", attempt: run.attempt_number)
abort "runner changed its durable replay" unless first.event.fetch("event_id") == run.events.first.event_key

changed = TaskView.new(
  task.workspace, task.task_key, "A changed request", task.input_context, task.expected_output,
  task.assigned_agent_profile, task.assigned_agent_profile_version
)
begin
  client.admit!(
    task: changed, run:, run_id: run.run_key,
    idempotency_key: "admit:#{run.run_key}", attempt: run.attempt_number
  )
  abort "runner accepted a changed idempotent request"
rescue RunnerClient::Conflict
end

puts "Rails and Go runner provider and execution contract passed"
