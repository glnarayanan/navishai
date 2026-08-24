require "test_helper"

class CrewArtifactPublisherTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    @message = add_inbound_message(@support_case, body: "The reset link says it has expired.")
    @knowledge = KnowledgeIngestion.create!(
      workspace: @workspace, membership: @owner, source_kind: :manual,
      title: "Reset links", content: "Reset links expire after one use.",
      url: nil, external_id: nil, upload: nil, expires_at: nil
    )
    @profiles = %w[support_investigator resolution_drafter support_reviewer].index_with do |role|
      @workspace.agent_profiles.find_by!(role_key: role)
    end
    @investigation = create_task(@profiles.fetch("support_investigator"), "Investigate")
    @draft = create_task(@profiles.fetch("resolution_drafter"), "Draft", dependencies: [ @investigation ])
    @review = create_task(@profiles.fetch("support_reviewer"), "Review", dependencies: [ @investigation ])
    @time = Time.current.change(usec: 0)
  end

  test "persists a cited scripted Support Crew journey with changes, reruns, versions, conflicts, and uncertainty" do
    start(@investigation)
    investigation = publish(@investigation, artifact_payload(
      kind: "investigation", body: "The customer used an expired reset link.",
      uncertainty: "The audit record does not show when the link was opened.",
      citations: [ conversation_citation, knowledge_citation ]
    ))
    review_and_approve(@investigation, "The cited sources support the finding.")
    assert @draft.reload.ready?
    assert @review.reload.ready?

    start(@draft)
    first_draft = publish(@draft, artifact_payload(
      kind: "draft", body: "We sent a new reset link. Please use it once.",
      uncertainty: "Delivery of the replacement link is not yet confirmed.", citations: [ knowledge_citation ]
    ))

    start(@review)
    first_review = publish(@review, artifact_payload(
      kind: "quality_review", body: "The draft claims a link was sent without case evidence.",
      uncertainty: "No outbound reset event is available.", review_outcome: "changes_requested",
      conflicts: [ { "summary" => "Unsupported send claim", "details" => "The case contains no reset-send event.", "severity" => "blocking" } ],
      change_requests: [ "Remove the claim that a new link was already sent." ], citations: [ conversation_citation ]
    ), target: first_draft)

    revised_draft = publish(@draft, artifact_payload(
      kind: "draft", body: "Your prior reset link expired. Request a new link, then open it once.",
      uncertainty: "None identified in the cited policy.", citations: [ conversation_citation, knowledge_citation ]
    ))
    final_review = publish(@review, artifact_payload(
      kind: "quality_review", body: "The revised draft matches the conversation and current policy.",
      uncertainty: "None identified in the cited sources.", review_outcome: "approved",
      citations: [ conversation_citation, knowledge_citation ]
    ), target: revised_draft)
    assert_includes first_review.execution_run.input_context, first_draft.body
    assert_includes revised_draft.execution_run.input_context, "Remove the claim that a new link was already sent."
    assert_includes final_review.execution_run.input_context, revised_draft.body

    review_and_approve(@draft, "The revised customer draft is grounded and clear.")
    review_and_approve(@review, "Quality review resolved the unsupported claim.")

    assert_equal [ 1, 2 ], @draft.artifacts.pluck(:version_number)
    assert_equal first_draft, revised_draft.supersedes_artifact
    assert_equal first_review, final_review.supersedes_artifact
    assert_equal revised_draft, final_review.target_artifact
    assert_equal "changes_requested", first_review.review_outcome
    assert_equal "Unsupported send claim", first_review.conflicts.first.fetch("summary")
    assert_equal [ "Remove the claim that a new link was already sent." ], first_review.change_requests
    assert_equal "approved", final_review.review_outcome
    assert_equal 2, investigation.citations.size
    assert @investigation.reload.completed?
    assert @draft.reload.completed?
    assert @review.reload.completed?
    assert_equal 5, @workspace.crew_artifacts.count
    assert_equal 5, AuditEvent.where(action: "crew.artifact_published", workspace: @workspace).count
    assert_not EmailDraft.exists?(support_case: @support_case)
  end

  test "rejects malformed output, unsupported claims, stale versions, and foreign citations" do
    start(@investigation)
    incomplete = prepare_run(@investigation, "not-json")
    assert_raises(CrewArtifactPublisher::InvalidOutput) { publish_run(@investigation, incomplete) }

    assert_raises(ExecutionLedger::InvalidRun) do
      complete_run(@investigation, artifact_payload(kind: "draft", body: "Wrong role."))
    end

    foreign_case = create_support_case(workspace: workspaces(:beta_support), contact: contacts(:bob),
      membership: memberships(:outsider_beta))
    foreign_message = add_inbound_message(foreign_case)
    foreign_locator = "conversation://#{foreign_case.conversation_id}/messages/#{foreign_message.id}"
    assert_raises(ExecutionLedger::InvalidRun) do
      complete_run(@investigation, artifact_payload(
        kind: "investigation", body: "Foreign citation.",
        citations: [ { "kind" => "conversation", "locator" => foreign_locator, "label" => "Foreign" } ]
      ))
    end
    assert_empty @investigation.artifacts
  end

  test "publication is idempotent, append only, and rolls back with its audit" do
    start(@investigation)
    run = complete_run(@investigation, artifact_payload(kind: "investigation", body: "Durable finding."))
    artifact = publish_run(@investigation, run)
    assert_equal artifact, publish_run(@investigation, run)
    assert_equal 1, @investigation.artifacts.count
    assert_raises(ActiveRecord::ReadOnlyRecord) { artifact.update!(body: "Changed") }
    assert_raises(ActiveRecord::StatementInvalid) do
      CrewArtifact.transaction(requires_new: true) { CrewArtifact.where(id: artifact.id).delete_all }
    end

    original = AuditEvent.method(:record!)
    AuditEvent.define_singleton_method(:record!) { |**| raise ActiveRecord::RecordInvalid, AuditEvent.new }
    begin
      assert_raises(ExecutionLedger::InvalidRun) do
        complete_run(@investigation, artifact_payload(kind: "investigation", body: "Second finding."))
      end
    ensure
      AuditEvent.define_singleton_method(:record!, original)
    end
    second = @investigation.execution_runs.order(:attempt_number).last
    assert_nil second.reload.crew_artifact
    assert second.running?
    assert_equal 1, @investigation.artifacts.count
  end

  private
    def create_task(profile, title, dependencies: [])
      CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: @support_case, profile:, title:,
        input_context: "Use the current conversation and approved knowledge.",
        expected_output: "Return strict v1 JSON with citations and uncertainty.", dependencies:
      )
    end

    def start(task)
      apply(task, :start)
    end

    def review_and_approve(task, body)
      apply(task, :request_review, body:)
      apply(task, :review, review_outcome: "approved", body:)
    end

    def apply(task, command, **attributes)
      task.reload
      CrewWork.apply!(workspace: @workspace, membership: @owner, task:, command:,
        expected_sequence: task.current_event.sequence_number, attributes:)
    end

    def publish(task, payload, target: nil)
      publish_run(task, complete_run(task, payload), target:)
    end

    def publish_run(task, run, target: nil)
      CrewArtifactPublisher.publish!(workspace: @workspace, task:, run:, target_artifact: target)
    end

    def prepare_run(task, output)
      @output_counter = @output_counter.to_i + 1
      run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: "artifact:#{task.id}:#{@output_counter}")
      run.define_singleton_method(:pending_test_output) { output }
      run
    end

    def complete_run(task, payload)
      output = JSON.generate(payload)
      run = prepare_run(task, output)
      ledger = ExecutionLedger.new(workspace: @workspace)
      events = [
        [ "run.admitted", { workspace_key: @workspace.runner_key, task_key: task.task_key, attempt: run.attempt_number } ],
        [ "run.started", { adapter: "scripted", scenario: "support journey", attempt: run.attempt_number } ],
        [ "output.produced", { text: output } ],
        [ "run.completed", { outcome: "completed" } ]
      ]
      events.each_with_index do |(type, data), index|
        ledger.ingest!(event: {
          "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
          "sequence" => index + 1, "event_type" => type,
      "occurred_at" => (@time + @output_counter.seconds + (index / 1000.0).seconds).iso8601(6),
          "data" => data.deep_stringify_keys
        })
      end
      run.reload
    end

    def artifact_payload(kind:, body:, uncertainty: "No uncertainty identified.", citations: nil, conflicts: [],
      change_requests: [], review_outcome: nil)
      {
        "schema_version" => 1, "kind" => kind, "body" => body, "uncertainty" => uncertainty,
        "citations" => citations || [ conversation_citation ], "conflicts" => conflicts, "change_requests" => change_requests,
        "review_outcome" => review_outcome
      }
    end

    def conversation_citation
      {
        "kind" => "conversation",
        "locator" => "conversation://#{@support_case.conversation_id}/messages/#{@message.id}",
        "label" => "Customer report"
      }
    end

    def knowledge_citation
      { "kind" => "knowledge", "locator" => @knowledge.current_version.citation_uri, "label" => "Reset link policy" }
    end
end
