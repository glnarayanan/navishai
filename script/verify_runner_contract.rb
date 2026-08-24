require_relative "../config/environment"

Profile = Data.define(:role_key)
Version = Data.define(
  :version_number, :instructions, :allowed_tools, :runtime_profile_key,
  :fallback_profile_keys, :timeout_seconds, :max_steps, :max_tool_calls, :review_policy
)
Workspace = Data.define(:runner_key)
Task = Data.define(
  :workspace, :task_key, :title, :input_context, :expected_output,
  :assigned_agent_profile, :assigned_agent_profile_version
)

secret = ENV.fetch("NAVISHAI_RUNNER_SHARED_SECRET")
address = ENV.fetch("NAVISHAI_RUNNER_ADDRESS")
client = RunnerClient.new(address:, secret:)
abort "runner is not ready for protocol v1" unless client.ready?

profile = Profile.new("support_investigator")
version = Version.new(
  3, "Investigate current evidence and state uncertainty.",
  %w[case_read conversation_read knowledge_search], "workspace_default", [ "fast" ],
  300, 10, 20, "required"
)
task = Task.new(
  Workspace.new("c9bb966b-1fe9-4304-bd51-404e4fd9a09c"),
  "fae7db72-e33b-46b9-8f9e-9a0dfdd56661", "Investigate sign-in failure",
  "Use the current case conversation and approved knowledge sources.",
  "State the cause, cite evidence, and name material uncertainty.", profile, version
)
run_id = "3d07f334-88ef-4fe4-a640-421e3ba79921"
idempotency_key = "admit:#{run_id}"

first = client.admit!(task:, run_id:, idempotency_key:, attempt: 1)
replay = client.admit!(task:, run_id:, idempotency_key:, attempt: 1)
abort "runner changed its durable replay" unless first.attributes == replay.attributes

changed = task.with(title: "A changed request")
begin
  client.admit!(task: changed, run_id:, idempotency_key:, attempt: 1)
  abort "runner accepted a changed idempotent request"
rescue RunnerClient::Conflict
end

puts "Rails and Go runner protocol v1 contract passed"
