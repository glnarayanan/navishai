require "test_helper"

class MemoryPublicationTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    @message = add_inbound_message(@support_case)
    @artifact = published_artifact
  end

  test "agent facts remain proposals until an authorized human accepts them" do
    proposal = MemoryPublication.propose!(
      workspace: @workspace, artifact: @artifact, memory_type: :profile,
      scope: @support_case.conversation.contact, topic: "preferred-contact-window",
      content: "Customer prefers contact after 14:00 UTC.", confidence: 0.7
    )
    duplicate = MemoryPublication.propose!(
      workspace: @workspace, artifact: @artifact, memory_type: :profile,
      scope: @support_case.conversation.contact, topic: "preferred-contact-window",
      content: "Customer prefers contact after 14:00 UTC.", confidence: 0.7
    )

    assert_equal proposal, duplicate
    assert proposal.proposed?
    assert_nil proposal.published_memory_record
    assert_no_difference "MemoryRecord.count" do
      viewer = Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
      assert_raises(Current::RoleAccessDenied) do
        MemoryPublication.review!(workspace: @workspace, proposal: proposal, membership: viewer, outcome: :accepted)
      end
    end

    MemoryPublication.review!(
      workspace: @workspace, proposal: proposal, membership: @owner,
      outcome: :accepted, reviewed_at: Time.current
    )

    memory = proposal.reload.published_memory_record
    assert proposal.accepted?
    assert memory.memory_type_profile?
    assert memory.authority_human_correction?
    assert_equal @owner, memory.source_membership
    assert_equal "memory-proposal://#{proposal.proposal_key}", memory.source_reference
    assert memory.memory_index_entry.pending?
    assert_equal %w[memory.proposal_created memory.proposal_reviewed],
      AuditEvent.where(workspace: @workspace, subject_type: "MemoryProposal", subject_id: proposal.id).order(:id).pluck(:action)
    assert_raises(ActiveRecord::StatementInvalid) do
      MemoryProposal.transaction(requires_new: true) do
        MemoryProposal.where(id: proposal.id).update_all(content: "Rewritten")
      end
    end
  end

  test "rejection is terminal and publishes no durable memory" do
    proposal = MemoryPublication.propose!(
      workspace: @workspace, artifact: @artifact, memory_type: :semantic,
      scope: @support_case, topic: "suspected-cause", content: "A network fault caused the issue.", confidence: 0.4
    )

    assert_no_difference "MemoryRecord.count" do
      MemoryPublication.review!(workspace: @workspace, proposal: proposal, membership: @owner, outcome: :rejected)
    end
    assert proposal.reload.rejected?
    assert_raises(MemoryPublication::Conflict) do
      MemoryPublication.review!(workspace: @workspace, proposal: proposal, membership: @owner, outcome: :accepted)
    end
  end

  test "only managers publish procedural memory and publication is idempotent" do
    member_user = User.create!(email_address: "memory-member@example.com", password: "password12345", verified_at: Time.current)
    member = Membership.create!(workspace: @workspace, user: member_user, role: :member)
    arguments = {
      workspace: @workspace, scope: @workspace, topic: "escalation-playbook",
      content: "Escalate blocked exports after one business day.", source_reference: "procedure://exports/v1",
      idempotency_key: "exports-v1"
    }

    assert_raises(Current::RoleAccessDenied) do
      MemoryPublication.publish_procedure!(**arguments, membership: member)
    end
    first = MemoryPublication.publish_procedure!(**arguments, membership: @owner)
    second = MemoryPublication.publish_procedure!(**arguments, membership: @owner)

    assert_equal first, second
    assert first.memory_type_procedural?
    assert first.authority_human_correction?
    assert_equal 1, AuditEvent.where(action: "memory.procedure_published", subject_id: first.id).count
    assert_raises(MemoryPublication::Conflict) do
      MemoryPublication.publish_procedure!(
        **arguments.merge(content: "Changed instructions"), membership: @owner
      )
    end
  end

  private
    def published_artifact
      profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
      task = CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: @support_case, profile: profile,
        title: "Investigate memory", input_context: "Use current case evidence.",
        expected_output: "Return a cited investigation.", dependencies: []
      )
      CrewWork.apply!(
        workspace: @workspace, membership: @owner, task: task, command: :start,
        expected_sequence: task.current_event.sequence_number, attributes: {}
      )
      locator = "conversation://#{@support_case.conversation_id}/messages/#{@message.id}"
      output = JSON.generate(
        "schema_version" => 2, "kind" => "investigation", "body" => "Customer stated a contact preference.",
        "uncertainty" => "The preference has not been confirmed by a human.",
        "citations" => [ {
          "kind" => "conversation",
          "locator" => locator,
          "label" => "Customer message"
        } ],
        "conflicts" => [], "change_requests" => [], "review_outcome" => nil, "memory_proposals" => [],
        "required_facts" => %w[customer_preference confirmation_status],
        "material_claims" => [
          {
            "key" => "customer_preference", "category" => "customer_account_fact",
            "text" => "The customer stated a contact preference.", "state" => "supported",
            "evidence" => [ { "kind" => "conversation", "locator" => locator } ]
          },
          {
            "key" => "confirmation_status", "category" => "product_technical_fact",
            "text" => "The preference has not been confirmed.", "state" => "supported",
            "evidence" => [ { "kind" => "conversation", "locator" => locator } ]
          }
        ],
        "proposed_actions" => [],
        "policy_checks" => ResolutionContractVersion::REVIEW_CHECKS.keys.sort.map do |check|
          { "check" => check, "status" => "passed" }
        end
      )
      ledger = ExecutionLedger.new(workspace: @workspace)
      run = ledger.prepare!(task: task, request_key: "memory-proposal-run")
      events = [
        [ "run.admitted", { workspace_key: @workspace.runner_key, task_key: task.task_key, attempt: 1 } ],
        [ "run.started", { adapter: "scripted", scenario: "memory proposal", attempt: 1 } ],
        [ "output.produced", { text: output } ],
        [ "run.completed", { outcome: "completed" } ]
      ]
      events.each_with_index do |(type, data), index|
        ledger.ingest!(event: {
          "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
          "sequence" => index + 1, "event_type" => type,
          "occurred_at" => (Time.current + (index / 1000.0).seconds).iso8601(6), "data" => data.deep_stringify_keys
        })
      end
      CrewArtifactPublisher.publish!(workspace: @workspace, task: task, run: run.reload)
    end
end
