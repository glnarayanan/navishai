require "test_helper"

class CrewWorkTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    @coordinator = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    @investigator = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
  end

  test "records an attributable task, evidence, handoff, review, and outcome as one durable timeline" do
    task = create_task

    assert task.ready?
    assert_equal @owner, task.owner_membership
    assert_equal @coordinator.current_version, task.assigned_agent_profile_version
    assert_equal %w[created], task.events.pluck(:event_kind)
    assert AuditEvent.where(action: "crew.task_created", actor: @owner.user, subject_id: task.id).exists?

    apply(task, :start)
    apply(task, :comment, body: "The customer reports that password reset links expire at once.")
    apply(task, :add_evidence, evidence_kind: "conversation", evidence_locator: "conversation:#{@support_case.conversation_id}:message:1",
      body: "The latest inbound message states the observed symptom.")
    apply(task, :handoff, agent_profile_id: @investigator.id, body: "Investigate the reset policy and recent account events.")
    apply(task, :request_review, body: "Check the evidence and proposed cause.")
    apply(task, :review, review_outcome: "approved", body: "Evidence supports the result and no claim exceeds it.")

    task.reload
    assert task.completed?
    assert_equal @investigator, task.assigned_agent_profile
    assert_equal @investigator.current_version, task.assigned_agent_profile_version
    assert_equal 7, task.current_event.sequence_number
    assert_equal %w[created status_changed comment evidence_added handoff review_requested outcome_recorded],
      task.events.pluck(:event_kind)
    evidence = task.events.find_by!(event_kind: "evidence_added")
    assert_equal "conversation", evidence.evidence_kind
    assert_equal "approved", task.current_event.review_outcome
    assert_equal "completed", task.current_event.outcome_kind
    assert task.events.all? { |event| event.actor_membership == @owner && event.actor_user == @owner.user }
  end

  test "dependencies gate work and completion releases dependents without erasing retry history" do
    prerequisite = create_task(title: "Gather facts")
    dependent = create_task(title: "Draft answer", profile: @investigator, dependencies: [ prerequisite ])
    assert dependent.pending?
    assert_raises(CrewWork::InvalidCommand) { apply(dependent, :start) }

    apply(prerequisite, :start)
    apply(prerequisite, :fail, body: "The source was unavailable.")
    apply(prerequisite, :retry, body: "The source is available now.")
    apply(prerequisite, :start)
    apply(prerequisite, :request_review, body: "Facts are ready for review.")
    apply(prerequisite, :review, review_outcome: "approved", body: "Facts are grounded in the case record.")

    assert dependent.reload.ready?
    assert_equal "All dependencies completed.", dependent.current_event.body
    assert_equal %w[failed completed], prerequisite.events.where(event_kind: "outcome_recorded").pluck(:outcome_kind)
    assert prerequisite.events.where(event_kind: "status_changed").exists?(body: "The source is available now.")
    assert_equal 1, dependent.dependencies.count
  end

  test "stale commands, viewers, non-managers, foreign records, and direct history changes fail closed" do
    task = create_task
    original_sequence = task.current_event.sequence_number
    apply(task, :start)
    assert_raises(CrewWork::StaleTask) do
      CrewWork.apply!(workspace: @workspace, membership: @owner, task:, command: :comment,
        expected_sequence: original_sequence, attributes: { body: "Stale" })
    end

    viewer_user = User.create!(email_address: "crew-viewer@example.com", password: "password12345", verified_at: Time.current)
    viewer = @workspace.memberships.create!(user: viewer_user, role: :viewer)
    assert_raises(Current::RoleAccessDenied) do
      CrewWork.apply!(workspace: @workspace, membership: viewer, task:, command: :comment,
        expected_sequence: task.reload.current_event.sequence_number, attributes: { body: "Not allowed" })
    end

    member_user = User.create!(email_address: "crew-member@example.com", password: "password12345", verified_at: Time.current)
    member = @workspace.memberships.create!(user: member_user, role: :member)
    apply(task, :request_review, body: "Review this result.")
    assert_raises(Current::RoleAccessDenied) do
      CrewWork.apply!(workspace: @workspace, membership: member, task:, command: :review,
        expected_sequence: task.reload.current_event.sequence_number,
        attributes: { review_outcome: "approved", body: "Not allowed" })
    end

    foreign_profile = begin
      foreign = workspaces(:beta_support)
      CrewConfiguration.install_defaults!(workspace: foreign)
      foreign.agent_profiles.find_by!(role_key: "support_coordinator")
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      CrewWork.create!(workspace: @workspace, membership: @owner, scope: @support_case,
        profile: foreign_profile, title: "Foreign", input_context: "Foreign", expected_output: "Must fail")
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      CrewTask.transaction(requires_new: true) { CrewTask.where(id: task.id).update_all(title: "Changed") }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      CrewTaskEvent.transaction(requires_new: true) { CrewTaskEvent.where(id: task.events.first.id).update_all(body: "Changed") }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      CrewTaskDependency.transaction(requires_new: true) do
        prerequisite = create_task(title: "Dependency")
        dependency = create_task(title: "Dependent", dependencies: [ prerequisite ]).dependency_links.first
        dependency.delete
      end
    end
  end

  test "audit failure rolls the work event and state back together" do
    task = create_task
    original_event = task.current_event
    original_record = AuditEvent.method(:record!)
    AuditEvent.define_singleton_method(:record!) { |**| raise ActiveRecord::RecordInvalid, AuditEvent.new }
    begin
      assert_raises(CrewWork::InvalidCommand) { apply(task, :start) }
    ensure
      AuditEvent.define_singleton_method(:record!, original_record)
    end

    assert task.reload.ready?
    assert_equal original_event, task.current_event
    assert_equal 1, task.events.count
  end

  test "account tasks use the Customer Success crew and policy snapshots do not drift" do
    analyst = @workspace.agent_profiles.find_by!(role_key: "account_analyst")
    account_task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: accounts(:acme), profile: analyst,
      title: "Review account health inputs", input_context: "Use current account facts and source records.",
      expected_output: "List current account facts and their sources."
    )
    assert_equal "account", account_task.scope_kind
    assert_equal accounts(:acme), account_task.account
    assert_equal "customer_success", account_task.crew_template.crew_kind

    task = create_task
    frozen_version = task.assigned_agent_profile_version
    CrewConfiguration.update_profile!(
      workspace: @workspace, membership: @owner, agent_profile: @coordinator,
      attributes: {
        expected_version_number: frozen_version.version_number,
        instructions: "Classify the case with current facts and state every gap.",
        allowed_tools: frozen_version.allowed_tools,
        runtime_profile_key: frozen_version.runtime_profile_key,
        fallback_profile_keys: frozen_version.fallback_profile_keys,
        timeout_seconds: frozen_version.timeout_seconds,
        max_steps: frozen_version.max_steps,
        max_tool_calls: frozen_version.max_tool_calls,
        review_policy: frozen_version.review_policy
      }
    )
    assert_not_equal frozen_version, @coordinator.reload.current_version
    apply(task, :comment, body: "The task keeps the policy it started with.")
    assert_equal frozen_version, task.reload.assigned_agent_profile_version
    assert_equal frozen_version, task.current_event.to_agent_profile_version
  end

  test "unknown dependencies and unattached events cannot alter the work graph" do
    assert_raises(CrewWork::InvalidCommand) { create_task(dependencies: [ 99_999_999 ]) }
    task = create_task
    assert_raises(ActiveRecord::StatementInvalid) do
      CrewTaskEvent.transaction(requires_new: true) do
        task.events.create!(
          workspace: @workspace, sequence_number: 2, event_kind: "comment", source: "web",
          actor_membership: @owner, actor_user: @owner.user,
          from_status: task.status, to_status: task.status,
          from_agent_profile: task.assigned_agent_profile, to_agent_profile: task.assigned_agent_profile,
          from_agent_profile_version: task.assigned_agent_profile_version,
          to_agent_profile_version: task.assigned_agent_profile_version,
          body: "This event is not linked to the task pointer."
        )
        CrewTaskEvent.connection.execute("SET CONSTRAINTS crew_task_events_require_link IMMEDIATE")
      end
    end
    assert_equal 1, task.events.count
  end

  test "byte bounds reject oversized task and event content before PostgreSQL errors" do
    assert_raises(CrewWork::InvalidCommand) do
      CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: @support_case, profile: @coordinator,
        title: "Bounded", input_context: "é" * 4_001, expected_output: "A bounded result."
      )
    end
    task = create_task
    assert_raises(CrewWork::InvalidCommand) { apply(task, :comment, body: "é" * 10_001) }
    assert_equal 1, task.events.count
  end

  private
    def create_task(title: "Investigate sign-in failure", profile: @coordinator, dependencies: [])
      CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: @support_case, profile:,
        title:, input_context: "Use the current case conversation and approved knowledge sources.",
        expected_output: "Find the cause, cite the case record, and state any uncertainty.", dependencies:
      )
    end

    def apply(task, command, **attributes)
      task.reload
      CrewWork.apply!(
        workspace: @workspace, membership: @owner, task:, command:,
        expected_sequence: task.current_event.sequence_number, attributes:
      )
    end
end
