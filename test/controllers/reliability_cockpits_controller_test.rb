require "test_helper"

class ReliabilityCockpitsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
  end

  test "a Manager reads all operating domains while a Member cannot enter or see navigation" do
    manager = @workspace.memberships.create!(
      user: User.create!(email_address: "reliability-manager@example.com", password: "password12345", verified_at: Time.current),
      role: :manager
    )
    sign_in_as manager.user

    get workspace_reliability_cockpit_path(@workspace)

    assert_response :success
    assert_select "h1", "Reliability"
    %w[Connectors\ and\ intake Job\ queue Runner\ and\ execution Customer\ sends Memory\ index Data\ protection].each do |title|
      assert_select ".reliability-group-copy > strong", title.tr("\\", "")
    end
    assert_select ".reliability-key dt", count: 5
    assert_select "a", text: "Inspect email", count: 0
    assert_select ".nav-label", "System health"

    sign_out
    member = @workspace.memberships.create!(
      user: User.create!(email_address: "reliability-member@example.com", password: "password12345", verified_at: Time.current),
      role: :member
    )
    sign_in_as member.user
    get workspace_support_cases_path(@workspace)
    assert_select ".nav-label", text: "System health", count: 0
    get workspace_reliability_cockpit_path(@workspace)
    assert_response :forbidden
  end

  test "foreign Workspace paths fail closed" do
    sign_in_as users(:owner)

    get workspace_reliability_cockpit_path(workspaces(:beta_support))

    assert_response :not_found
  end

  test "unknown customer sends expose investigation but no resend action" do
    support_case = create_support_case
    inbox = @workspace.shared_email_inboxes.create!(
      name: "Support", email_address: "support@example.com", credential_key: "support"
    )
    thread = @workspace.email_threads.create!(
      shared_email_inbox: inbox, conversation: support_case.conversation,
      thread_key: "reliability-thread"
    )
    draft = @workspace.email_drafts.create!(
      support_case:, email_thread: thread, conversation: support_case.conversation,
      updated_by: @owner.user, body: "Frozen customer message", status: :sending
    )
    delivery = @workspace.outbound_email_deliveries.create!(
      email_draft: draft, shared_email_inbox: inbox, email_thread: thread,
      conversation: support_case.conversation, actor_membership: @owner, actor_user: @owner.user,
      idempotency_key: "reliability-unknown", message_id: "reliability@navishai.local",
      from_address: inbox.email_address, to_address: "customer@example.net", subject: "Reply",
      body: draft.body, status: :unknown, failure_code: "unknown_outcome", started_at: 10.minutes.ago
    )
    sign_in_as users(:owner)

    get workspace_reliability_cockpit_path(@workspace)

    assert_response :success
    assert_select "#email-send-#{delivery.id}", text: /Do not resend/
    assert_select "#email-send-#{delivery.id} a", text: "Investigate exact send", count: 1
    assert_select "#email-send-#{delivery.id} form", count: 0
    assert_select "#email-send-#{delivery.id}", text: /Never retry from this cockpit/
  end

  test "memory recovery queues failed work once and stays idempotent while pending" do
    memory = @workspace.memory_records.create!(
      memory_type: :semantic, scope_kind: :workspace, topic: "recovery",
      content: "Authoritative source", authority: :source_record, origin_kind: :system,
      source_reference: "test://recovery", source_digest: Digest::SHA256.hexdigest("source"),
      observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 1,
      retention_policy: :indefinite
    )
    entry = @workspace.memory_index_entries.create!(
      memory_record: memory, status: :failed, attempt_count: 1,
      failure_code: "remote_unavailable", last_attempted_at: 5.minutes.ago
    )
    sign_in_as users(:owner)

    assert_difference -> { @workspace.audit_events.where(action: "memory.index_reconstructed").count }, 1 do
      post reconstruct_memory_workspace_reliability_cockpit_path(@workspace)
    end
    assert_redirected_to workspace_reliability_cockpit_path(@workspace, anchor: "memory")
    assert_match(/Queued 1 Memory record/, flash[:notice])

    post reconstruct_memory_workspace_reliability_cockpit_path(@workspace)
    assert_match(/Queued 0 Memory records/, flash[:notice])
    assert entry.reload.indexing?
  end

  test "large operational history keeps exact totals and bounded detail" do
    51.times do |index|
      memory = @workspace.memory_records.create!(
        memory_type: :semantic, scope_kind: :workspace, topic: "reliability-#{index}",
        content: "Authoritative source #{index}", authority: :source_record, origin_kind: :system,
        source_reference: "test://reliability/#{index}",
        source_digest: Digest::SHA256.hexdigest("source-#{index}"),
        observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 1,
        retention_policy: :indefinite
      )
      @workspace.memory_index_entries.create!(
        memory_record: memory, status: :failed, attempt_count: 1,
        failure_code: "remote_unavailable", last_attempted_at: 10.minutes.ago
      )
      @workspace.runtime_installations.create!(
        detection_key: Digest::SHA256.hexdigest("runtime-#{index}"), adapter_key: "runtime_#{index}",
        protocol_version: "v1", executable_path: "/opt/navishai/runtime-#{index}",
        executable_version: "runtime #{index}", account_metadata: {}, capabilities: [],
        minimum_version: "1", maximum_version: "1", compatibility_status: "compatible",
        incompatibility_reason: "", health_status: "available", checked_at: Time.current
      )
      OperationalCheck.create!(
        workspace: @workspace, check_kind: OperationalCheck::CHECK_KINDS[index % OperationalCheck::CHECK_KINDS.size],
        result: :passed, result_code: "verified", evidence_digest: Digest::SHA256.hexdigest("check-#{index}"),
        source_commit: "c" * 40, checked_at: Time.current - index.minutes
      )
    end
    sign_in_as users(:owner)
    queries = []
    subscriber = lambda do |*, payload|
      queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA CACHE])
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get workspace_reliability_cockpit_path(@workspace)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_response :success
    assert_select "#memory .reliability-group-copy", text: /51 failed/
    # Bounded detail plus one row per operational check kind.
    assert_select ".reliability-item", count: 44 + OperationalCheck::CHECK_KINDS.size
    assert_operator queries.size, :<=, 90
    assert_operator elapsed, :<, 5
  end
end
