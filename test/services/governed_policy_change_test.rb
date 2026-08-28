require "test_helper"

class GovernedPolicyChangeTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case(workspace: @workspace, membership: @owner)
    @account = @support_case.conversation.contact.account
    @family = @workspace.resolution_contract_families.find_by!(family_key: "support_resolution")
    @profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    @runtime = approve_scripted_runtime(workspace: @workspace, membership: @owner)
  end

  test "preview is deterministic typed bounded and has a stable digest including no-change" do
    proposal = propose(scope_kind: "support_case", scope_ids: [ @support_case.id ])

    first = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)
    second = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)

    assert_equal first.evidence_digest, second.evidence_digest
    assert_equal first.results_digest, second.results_digest
    assert_equal first.results, second.results
    assert_equal [ "support_case" ], first.results.pluck("subject_kind")
    assert first.results.all? { |result| result.keys.sort == GovernedPolicyPreview::RESULT_KEYS }
    assert first.results.all? { |result| result.fetch("facts").all? { |fact| fact.keys.sort == %w[key type value] } }
    assert first.results.any? { |result| result.fetch("changes").include?("budget") }

    unchanged = propose(
      scope_kind: "account", scope_ids: [ @account.id ],
      contract: contract_attributes, profile: profile_attributes
    )
    no_change = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal: unchanged)
    assert_equal "no_change", no_change.results.sole.fetch("result")
    assert_empty no_change.results.sole.fetch("changes")
  end

  test "preview explains grounding review routing fallback denial and budget decisions" do
    grounding = preview_for(
      contract: changed_contract_attributes.merge(missing_items_block: false),
      profile: profile_attributes.merge(review_policy: "on_policy_flag")
    ).results.sole
    assert_equal "blocked", grounding.dig("old_decision", "grounding")
    assert_equal "needs_human", grounding.dig("proposed_decision", "grounding")
    assert_equal "required", grounding.dig("old_decision", "quality_review", "requirement")
    assert_equal "on_policy_flag", grounding.dig("proposed_decision", "quality_review", "requirement")
    assert_equal "eligible", grounding.dig("old_decision", "routing")

    @runtime.update!(profile_keys: %w[fast workspace_default])
    fallback = preview_for(
      contract: contract_attributes,
      profile: profile_attributes.merge(runtime_profile_key: "thorough", fallback_profile_keys: [ "fast" ])
    ).results.sole
    assert_equal "fast", fallback.dig("proposed_decision", "fallback")
    assert_equal "eligible", fallback.dig("proposed_decision", "routing")

    denied = preview_for(
      contract: contract_attributes,
      profile: profile_attributes.merge(runtime_profile_key: "thorough", fallback_profile_keys: [])
    ).results.sole
    assert_equal "denied", denied.dig("proposed_decision", "routing")
    assert_match(/incompatible:/, denied.dig("proposed_decision", "fallback"))
    assert_equal "within_budget", denied.dig("old_decision", "budget", "result")
    assert_equal GovernedPolicyPreview::RESULT_KEYS, denied.keys.sort
  end

  test "preview has no runner search integration or customer-send effect" do
    proposal = propose(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    calls = [
      [ RunnerClient, :new ], [ PublicWebResearch, :perform! ], [ HumanEmailSend, :send! ],
      [ HumanIntercomSend, :send! ], [ IntercomOutboundSync, :deliver! ]
    ]

    with_forbidden_calls(calls) do
      assert GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)
    end
  end

  test "Owner and Admin may govern policy while Manager Member and Viewer fail closed" do
    admin = membership(:admin)
    manager = membership(:manager)
    member = membership(:member)
    viewer = membership(:viewer)

    [ @owner, admin ].each do |actor|
      proposal = propose(membership: actor, scope_kind: "support_case", scope_ids: [ @support_case.id ])
      preview = GovernedPolicyChange.preview!(workspace: @workspace, membership: actor, proposal:)
      publication = GovernedPolicyChange.publish!(workspace: @workspace, membership: actor, proposal:, preview:)
      GovernedPolicyChange.rollback!(
        workspace: @workspace, membership: actor, publication:,
        expected_publication_id: publication.id, reason: "Canary check complete"
      )
    end

    [ manager, member, viewer ].each do |actor|
      assert_raises(Current::RoleAccessDenied) do
        propose(membership: actor, scope_kind: "support_case", scope_ids: [ @support_case.id ])
      end
      proposal = propose(scope_kind: "support_case", scope_ids: [ @support_case.id ])
      assert_raises(Current::RoleAccessDenied) do
        GovernedPolicyChange.preview!(workspace: @workspace, membership: actor, proposal:)
      end
    end
  end

  test "cross Workspace access stale security and unavailable sources deny without publication" do
    proposal = propose(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    preview = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)

    same_organization = workspaces(:acme_success)
    same_organization_owner = same_organization.memberships.create!(
      user: User.create!(
        email_address: "same-org-policy-owner@example.com", password: "password12345", verified_at: Time.current
      ),
      role: :owner
    )
    foreign_organization = workspaces(:beta_support)
    foreign_organization_owner = foreign_organization.memberships.create!(
      user: User.create!(
        email_address: "foreign-org-policy-owner@example.com", password: "password12345", verified_at: Time.current
      ),
      role: :owner
    )
    [ [ same_organization, same_organization_owner ],
      [ foreign_organization, foreign_organization_owner ] ].each do |workspace, actor|
      assert_raises(ActiveRecord::RecordNotFound) do
        GovernedPolicyChange.preview!(workspace:, membership: actor, proposal:)
      end
    end
    assert_raises(Current::RoleAccessDenied) do
      GovernedPolicyChange.preview!(
        workspace: foreign_organization, membership: memberships(:outsider_beta), proposal:
      )
    end

    @runtime.update!(approved: false, approved_by_membership: nil, approved_by_user: nil, approved_at: nil)
    assert_raises(GovernedPolicyChange::StalePreview) do
      GovernedPolicyChange.publish!(workspace: @workspace, membership: @owner, proposal:, preview:)
    end
    assert_equal 0, @workspace.governed_policy_publications.count

    unavailable = propose(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    missing_preview = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal: unavailable)
    @support_case.update!(status: :closed, resolved_at: Time.current, closed_at: Time.current)
    assert_raises(GovernedPolicyChange::UnavailableSource) do
      GovernedPolicyChange.publish!(
        workspace: @workspace, membership: @owner, proposal: unavailable, preview: missing_preview
      )
    end
  end

  test "missing preview and invalid current security deny publication" do
    proposal = propose(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    assert_raises(GovernedPolicyChange::InvalidChange) do
      GovernedPolicyChange.publish!(workspace: @workspace, membership: @owner, proposal:, preview: nil)
    end

    insecure = propose(
      scope_kind: "support_case", scope_ids: [ @support_case.id ],
      contract: changed_contract_attributes.merge(
        mandatory_review_checks: ResolutionContractVersion::REVIEW_CHECKS.keys - [ "human_authority_preserved" ]
      )
    )
    preview = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal: insecure)
    assert_raises(GovernedPolicyChange::StalePreview) do
      GovernedPolicyChange.publish!(workspace: @workspace, membership: @owner, proposal: insecure, preview:)
    end
    assert_equal 0, @workspace.governed_policy_publications.count
  end

  test "explicit case Account and one-profile canaries freeze future work and rollback preserves history" do
    case_publication = publish(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    account_publication = publish(scope_kind: "account", scope_ids: [ @account.id ])
    profile_publication = publish(scope_kind: "agent_profile", scope_ids: [ @profile.id ])

    assert_equal [ @support_case.id ], case_publication.support_cases.pluck(:id)
    assert_equal [ @account.id ], account_publication.accounts.pluck(:id)
    assert_equal @profile, profile_publication.agent_profile
    assert_nil case_publication.successor
    assert_nil account_publication.successor
    assert_nil profile_publication.successor

    task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: @profile,
      title: "Policy canary", input_context: "Retained facts", expected_output: "Typed result"
    )
    assert_equal case_publication, task.governed_policy_publication
    assert_equal case_publication.agent_profile_version, task.assigned_agent_profile_version
    assert_equal case_publication.resolution_contract_version, task.resolution_contract_version

    rolled_back = GovernedPolicyChange.rollback!(
      workspace: @workspace, membership: @owner, publication: case_publication,
      expected_publication_id: case_publication.id, reason: "Observed canary mismatch"
    )
    future = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: @profile,
      title: "After rollback", input_context: "Retained facts", expected_output: "Typed result"
    )

    assert_equal rolled_back, future.governed_policy_publication
    assert_equal case_publication.proposal.prior_agent_profile_version, future.assigned_agent_profile_version
    assert_equal case_publication.agent_profile_version, task.reload.assigned_agent_profile_version
    assert_equal case_publication, task.governed_policy_publication
  end

  test "legacy contract and profile publication cannot bypass governed preview" do
    assert_raises(ResolutionContractConfiguration::InvalidConfiguration) do
      ResolutionContractConfiguration.publish!(
        workspace: @workspace, membership: @owner, family: @family,
        attributes: contract_attributes.merge(
          expected_current_version_id: @family.current_version_id,
          execution_budget_units: @family.current_version.execution_budget_units - 10
        )
      )
    end
    assert_raises(CrewConfiguration::InvalidConfiguration) do
      CrewConfiguration.update_profile!(
        workspace: @workspace, membership: @owner, agent_profile: @profile,
        attributes: profile_attributes.merge(
          expected_version_number: @profile.current_version.version_number,
          instructions: @profile.current_version.instructions,
          allowed_tools: @profile.current_version.allowed_tools,
          memory_required: @profile.current_version.memory_required,
          review_policy: "on_policy_flag"
        )
      )
    end
    assert_equal "required", @profile.reload.current_version.review_policy
  end

  test "canonical preview digests preserve false and publication binds stored payloads" do
    proposal = propose(
      scope_kind: "support_case", scope_ids: [ @support_case.id ],
      contract: changed_contract_attributes.merge(missing_items_block: false)
    )
    preview = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)
    assert_equal false, preview.source_snapshot.dig("proposal", "candidate_contract", "missing_items_block")
    assert_equal stable_digest(preview.source_snapshot), preview.evidence_digest
    assert_equal stable_digest(preview.results), preview.results_digest

    without_append_only_trigger("governed_policy_previews") do
      GovernedPolicyPreview.where(id: preview.id).update_all(
        source_snapshot: preview.source_snapshot.deep_merge(
          "proposal" => { "candidate_contract" => { "missing_items_block" => true } }
        )
      )
    end
    assert_raises(GovernedPolicyChange::StalePreview) do
      GovernedPolicyChange.publish!(workspace: @workspace, membership: @owner, proposal:, preview: preview.reload)
    end
  end

  test "expired proposal preview and publication evidence fails with bounded domain errors" do
    proposal = propose(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    preview = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)
    publication = GovernedPolicyChange.publish!(workspace: @workspace, membership: @owner, proposal:, preview:)

    without_append_only_trigger("governed_policy_publications") do
      GovernedPolicyPublication.where(id: publication.id).update_all(expired_at: Time.current)
    end
    assert_raises(GovernedPolicyChange::UnavailableSource) do
      GovernedPolicyChange.rollback!(
        workspace: @workspace, membership: @owner, publication: publication.reload,
        expected_publication_id: publication.id, reason: "Expired evidence"
      )
    end

    without_append_only_trigger("governed_policy_previews") do
      GovernedPolicyPreview.where(id: preview.id).update_all(expired_at: Time.current)
    end
    assert_raises(GovernedPolicyChange::UnavailableSource) do
      GovernedPolicyChange.publish!(workspace: @workspace, membership: @owner, proposal:, preview: preview.reload)
    end
  end

  test "publication and subject shapes reject mismatched immutable evidence" do
    proposal = propose(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    preview = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)
    wrong_contract = @workspace.resolution_contract_versions
      .where.not(id: proposal.resolution_contract_version_id).first!
    invalid = @workspace.governed_policy_publications.new(
      proposal:, preview:, action: "canary", resolution_contract_version: wrong_contract,
      agent_profile_version: proposal.agent_profile_version, reason: "Invalid evidence",
      created_by_membership: @owner, created_by_user: @owner.user, published_at: Time.current
    )
    assert_not invalid.valid?

    duplicate = proposal.subjects.build(
      workspace: @workspace, subject_kind: "support_case", support_case: @support_case
    )
    assert_not duplicate.valid?

    case_publication = GovernedPolicyChange.publish!(
      workspace: @workspace, membership: @owner, proposal:, preview:
    )
    account_proposal = propose(scope_kind: "account", scope_ids: [ @account.id ])
    account_preview = GovernedPolicyChange.preview!(
      workspace: @workspace, membership: @owner, proposal: account_proposal
    )
    cross_scope = @workspace.governed_policy_publications.new(
      proposal: account_proposal, preview: account_preview, supersedes_publication: case_publication,
      action: "canary", resolution_contract_version: account_proposal.resolution_contract_version,
      agent_profile_version: account_proposal.agent_profile_version, reason: "Invalid scope chain",
      created_by_membership: @owner, created_by_user: @owner.user, published_at: Time.current
    )
    assert_not cross_scope.valid?
    assert_database_rejects { GovernedPolicyPublication.insert_all!([ cross_scope.attributes.except("id") ]) }
  end

  test "task events retain exact policy decisions across rollback and handoff" do
    publication = publish(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: @profile,
      title: "Frozen task", input_context: "Facts", expected_output: "Result"
    )
    created = task.current_event
    assert_equal publication, created.to_governed_policy_publication
    assert_equal publication.resolution_contract_version, created.to_resolution_contract_version
    assert_equal publication.agent_profile_version, created.to_agent_profile_version

    GovernedPolicyChange.rollback!(
      workspace: @workspace, membership: @owner, publication:,
      expected_publication_id: publication.id, reason: "Return future work"
    )
    other_profile = @workspace.agent_profiles.find_by!(role_key: "resolution_drafter")
    CrewWork.apply!(
      workspace: @workspace, membership: @owner, task:, command: "handoff",
      expected_sequence: task.current_event.sequence_number,
      attributes: { agent_profile_id: other_profile.id, body: "Hand off with frozen policy history" }
    )
    handoff = task.reload.current_event

    assert_equal publication, handoff.from_governed_policy_publication
    assert_nil handoff.to_governed_policy_publication
    assert_equal publication.resolution_contract_version, handoff.from_resolution_contract_version
    assert_equal @family.current_version, handoff.to_resolution_contract_version
    assert_equal publication, created.reload.to_governed_policy_publication
  end

  test "governed run admission freezes one combined contract budget" do
    proposal = propose(
      scope_kind: "support_case", scope_ids: [ @support_case.id ],
      contract: changed_contract_attributes.merge(execution_budget_units: 1_000)
    )
    preview = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)
    GovernedPolicyChange.publish!(workspace: @workspace, membership: @owner, proposal:, preview:)
    task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: @profile,
      title: "Budgeted task", input_context: "Facts", expected_output: "Result"
    )
    run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: SecureRandom.uuid)

    assert_operator run.max_input_units, :>, 0
    assert_operator run.max_output_units, :>, 0
    assert_operator run.max_input_units + run.max_output_units, :<=, 1_000
    ingest_event(run, 1, "run.admitted", {
      workspace_key: @workspace.runner_key, task_key: task.task_key, attempt: 1
    })
    ingest_event(run, 2, "run.started", { adapter: run.selected_adapter_key, scenario: "budget", attempt: 1 })
    assert_raises(ExecutionLedger::EventConflict) do
      ingest_usage(run, input_units: run.max_input_units, output_units: run.max_output_units + 1)
    end
  end

  test "budget one is rejected while non-canary runs keep exact router limits" do
    error = assert_raises(GovernedPolicyChange::InvalidChange) do
      propose(
        scope_kind: "support_case", scope_ids: [ @support_case.id ],
        contract: changed_contract_attributes.merge(execution_budget_units: 1)
      )
    end
    assert_match(/positive input and output/, error.message)

    outside_case = create_support_case(
      subject: "Outside canary", workspace: @workspace, membership: @owner
    )
    task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: outside_case, profile: @profile,
      title: "Baseline limits", input_context: "Facts", expected_output: "Result"
    )
    run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: SecureRandom.uuid)
    assert_nil run.governed_policy_publication
    assert_equal @runtime.max_input_units, run.max_input_units
    assert_equal @runtime.max_output_units, run.max_output_units
  end

  test "database rejects same-Workspace task event and run policy tuple mismatches" do
    publication = publish(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: @profile,
      title: "Projection integrity", input_context: "Facts", expected_output: "Result"
    )
    run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: SecureRandom.uuid)
    wrong_contract_id = publication.proposal.prior_resolution_contract_version_id

    assert_database_rejects do
      CrewTask.insert_all!([ task.attributes.except("id", "current_event_id").merge(
        "task_key" => SecureRandom.uuid, "title" => "Mismatched task",
        "resolution_contract_version_id" => wrong_contract_id,
        "created_at" => Time.current, "updated_at" => Time.current
      ) ])
    end
    assert_database_rejects do
      event = task.current_event
      CrewTaskEvent.insert_all!([ event.attributes.except("id").merge(
        "sequence_number" => event.sequence_number + 1, "event_kind" => "comment",
        "body" => "Mismatched event", "to_resolution_contract_version_id" => wrong_contract_id,
        "created_at" => Time.current, "updated_at" => Time.current
      ) ])
    end
    assert_database_rejects do
      ExecutionRun.insert_all!([ run.attributes.except("id", "current_event_id").merge(
        "run_key" => SecureRandom.uuid, "request_key" => SecureRandom.uuid,
        "attempt_number" => run.attempt_number + 1,
        "resolution_contract_version_id" => wrong_contract_id,
        "created_at" => Time.current, "updated_at" => Time.current
      ) ])
    end
  end

  test "database binds shared-version rollback publications across task event and run" do
    first_canary = publish(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    first_rollback = GovernedPolicyChange.rollback!(
      workspace: @workspace, membership: @owner, publication: first_canary,
      expected_publication_id: first_canary.id, reason: "First rollback"
    )
    task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: @profile,
      title: "Rollback A task", input_context: "Facts", expected_output: "Result"
    )
    run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: SecureRandom.uuid)

    second_canary = publish(scope_kind: "support_case", scope_ids: [ @support_case.id ])
    second_rollback = GovernedPolicyChange.rollback!(
      workspace: @workspace, membership: @owner, publication: second_canary,
      expected_publication_id: second_canary.id, reason: "Second rollback"
    )
    assert_equal first_rollback.resolution_contract_version, second_rollback.resolution_contract_version
    assert_equal first_rollback.agent_profile_version, second_rollback.agent_profile_version

    assert_database_rejects do
      ExecutionRun.insert_all!([ run.attributes.except("id", "current_event_id").merge(
        "run_key" => SecureRandom.uuid, "request_key" => SecureRandom.uuid,
        "attempt_number" => run.attempt_number + 1,
        "governed_policy_publication_id" => second_rollback.id,
        "created_at" => Time.current, "updated_at" => Time.current
      ) ])
    end
    assert_database_rejects do
      CrewTaskEvent.insert_all!([ event_attributes(task).merge(
        "to_governed_policy_publication_id" => first_rollback.id,
        "to_resolution_contract_version_id" => nil
      ) ])
    end
    assert_database_rejects do
      result = CrewTaskEvent.insert_all!([ event_attributes(task) ], returning: %w[id])
      event_id = result.rows.sole.sole
      CrewTask.where(id: task.id).update_all(
        current_event_id: event_id, governed_policy_publication_id: second_rollback.id
      )
    end
  end

  private
    def propose(membership: @owner, scope_kind:, scope_ids:, contract: changed_contract_attributes,
      profile: changed_profile_attributes)
      GovernedPolicyChange.propose!(
        workspace: @workspace, membership:, family: @family, profile: @profile,
        scope_kind:, scope_ids:, contract_attributes: contract, profile_attributes: profile,
        reason: "Bounded pilot policy"
      )
    end

    def publish(scope_kind:, scope_ids:)
      proposal = propose(scope_kind:, scope_ids:)
      preview = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)
      GovernedPolicyChange.publish!(workspace: @workspace, membership: @owner, proposal:, preview:)
    end

    def preview_for(contract:, profile:)
      proposal = propose(
        scope_kind: "support_case", scope_ids: [ @support_case.id ], contract:, profile:
      )
      GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)
    end

    def contract_attributes
      version = @family.current_version
      {
        required_claim_categories: version.required_claim_categories,
        evidence_freshness_days: version.evidence_freshness_days,
        mandatory_review_checks: version.mandatory_review_checks,
        execution_budget_units: version.execution_budget_units,
        missing_items_block: version.missing_items_block
      }
    end

    def changed_contract_attributes
      contract_attributes.merge(execution_budget_units: @family.current_version.execution_budget_units - 1)
    end

    def profile_attributes
      version = @profile.current_version
      {
        runtime_profile_key: version.runtime_profile_key,
        fallback_profile_keys: version.fallback_profile_keys,
        timeout_seconds: version.timeout_seconds,
        max_steps: version.max_steps,
        max_tool_calls: version.max_tool_calls,
        review_policy: version.review_policy
      }
    end

    def changed_profile_attributes
      profile_attributes.merge(runtime_profile_key: "thorough", fallback_profile_keys: [ "fast" ])
    end

    def membership(role)
      user = User.create!(
        email_address: "policy-#{role}-#{SecureRandom.hex(4)}@example.com",
        password: "password12345", verified_at: Time.current
      )
      @workspace.memberships.create!(user:, role:)
    end

    def with_forbidden_calls(calls, &block)
      klass, method_name = calls.first
      return block.call unless klass

      original = klass.method(method_name)
      klass.define_singleton_method(method_name) { |*| raise "preview crossed external-effect seam #{klass}.#{method_name}" }
      with_forbidden_calls(calls.drop(1), &block)
    ensure
      klass&.define_singleton_method(method_name, original) if original
    end

    def stable_digest(value)
      canonical = lambda do |item|
        case item
        when Hash
          item.keys.map(&:to_s).sort.to_h do |key|
            source_key = item.key?(key) ? key : key.to_sym
            [ key, canonical.call(item.fetch(source_key)) ]
          end
        when Array then item.map { |value| canonical.call(value) }
        else item
        end
      end
      Digest::SHA256.hexdigest(JSON.generate(canonical.call(value)))
    end

    def without_append_only_trigger(table)
      connection = ActiveRecord::Base.connection
      connection.execute("ALTER TABLE #{table} DISABLE TRIGGER USER")
      yield
    ensure
      connection&.execute("ALTER TABLE #{table} ENABLE TRIGGER USER")
    end

    def ingest_usage(run, input_units:, output_units:)
      ingest_event(run, run.current_sequence + 1, "usage.observed", { input_units:, output_units: })
    end

    def ingest_event(run, sequence, event_type, data)
      ExecutionLedger.ingest!(workspace: @workspace, event: {
        protocol_version: RunnerProtocol::VERSION, event_id: SecureRandom.uuid, run_id: run.run_key,
        sequence:, event_type:, occurred_at: Time.current.iso8601, data:
      })
    end

    def assert_database_rejects(&block)
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true, &block)
      end
    end

    def event_attributes(task)
      {
        "workspace_id" => @workspace.id,
        "crew_task_id" => task.id,
        "sequence_number" => task.current_event.sequence_number + 1,
        "event_kind" => "comment",
        "source" => "web",
        "actor_membership_id" => @owner.id,
        "actor_user_id" => @owner.user_id,
        "from_status" => task.status,
        "to_status" => task.status,
        "from_agent_profile_id" => task.assigned_agent_profile_id,
        "to_agent_profile_id" => task.assigned_agent_profile_id,
        "from_agent_profile_version_id" => task.assigned_agent_profile_version_id,
        "to_agent_profile_version_id" => task.assigned_agent_profile_version_id,
        "from_governed_policy_publication_id" => task.governed_policy_publication_id,
        "to_governed_policy_publication_id" => task.governed_policy_publication_id,
        "from_resolution_contract_version_id" => task.resolution_contract_version_id,
        "to_resolution_contract_version_id" => task.resolution_contract_version_id,
        "body" => "Direct projection test",
        "created_at" => Time.current,
        "updated_at" => Time.current
      }
    end
end
