require "test_helper"

class WorkspaceContentExpiryTest < ActiveSupport::TestCase
  test "request is owner attributed and idempotent while pending" do
    workspace = workspaces(:acme_support)
    policy = workspace.create_workspace_data_policy!(content_retention_days: 30, audit_retention_days: 365)
    now = Time.zone.parse("2026-08-24 12:00:00")

    assert_difference [ "WorkspaceContentExpiryRun.count", "AuditEvent.count" ], 1 do
      @run = WorkspaceContentExpiry.request!(
        workspace:, membership: memberships(:owner_support), source: :web, requested_at: now
      )
    end

    assert_equal now - policy.content_retention_days.days, @run.cutoff_at
    enqueued_count = ActiveJob::Base.queue_adapter.enqueued_jobs.count
    assert_equal @run, WorkspaceContentExpiry.request!(
      workspace:, membership: memberships(:owner_support), source: :web, requested_at: now
    )
    assert_equal enqueued_count, ActiveJob::Base.queue_adapter.enqueued_jobs.count
    audit = AuditEvent.order(:id).last
    assert_equal "workspace.content_expiry_requested", audit.action
    assert_equal users(:owner), audit.actor
  end

  test "database expiry removes plaintext but preserves another workspace and audit history" do
    workspace = workspaces(:acme_support)
    other_workspace = workspaces(:beta_support)
    message = ConversationThread.start_inbound!(
      workspace:, contact: contacts(:alice), subject: "Private subject", body: "Private body",
      occurred_at: Time.current, source: :integration
    )
    other_message = ConversationThread.start_inbound!(
      workspace: other_workspace, contact: contacts(:bob), subject: "Other subject", body: "Other body",
      occurred_at: Time.current, source: :integration
    )
    original_audit_count = workspace.audit_events.count
    original_other_body = other_message.body
    cutoff = 1.day.from_now

    count = ActiveRecord::Base.connection.select_value(
      "SELECT expire_workspace_content(#{workspace.id}, #{ActiveRecord::Base.connection.quote(cutoff)})"
    ).to_i

    assert_operator count, :>, 0
    assert_equal "[Expired by retention policy]", message.reload.body
    assert_equal original_other_body, other_message.reload.body
    assert_equal original_audit_count, workspace.audit_events.count
    assert_match(/expired-/, workspace.source_identity_keys.first.reload.normalized_value)
  end

  test "expiry redacts governed preview content while preserving immutable lineage and audit" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    proposal, preview, publication = create_governed_policy_canary(workspace:, membership: owner)
    subject_ids = proposal.subject_ids
    audit_ids = workspace.audit_events.where(action: %w[
      governed_policy.proposed governed_policy.canary_published
    ]).ids
    evidence_digest = preview.evidence_digest
    results_digest = preview.results_digest

    expire_workspace_content(workspace, 1.day.from_now)

    assert_equal "[Expired by retention policy]", proposal.reload.reason
    assert_equal "[Expired by retention policy]", publication.reload.reason
    assert_equal({ "retention" => "expired" }, preview.reload.source_snapshot)
    assert preview.results.all? { |result| result.fetch("result") == "expired" }
    assert_equal evidence_digest, preview.evidence_digest
    assert_equal results_digest, preview.results_digest
    assert_equal subject_ids, proposal.subject_ids
    assert_equal audit_ids.sort, workspace.audit_events.where(id: audit_ids).ids.sort
    assert_raises(GovernedPolicyChange::UnavailableSource) do
      GovernedPolicyChange.publish!(workspace:, membership: owner, proposal:, preview:)
    end
    assert_raises(GovernedPolicyChange::UnavailableSource) do
      GovernedPolicyChange.rollback!(
        workspace:, membership: owner, publication:, expected_publication_id: publication.id,
        reason: "Expired evidence cannot authorize rollback"
      )
    end
  end

  test "external cleanup failure leaves database content and records a visible failure" do
    workspace = workspaces(:acme_support)
    message = ConversationThread.start_inbound!(
      workspace:, contact: contacts(:alice), subject: "Private subject", body: "Private body",
      occurred_at: Time.current, source: :integration
    )
    original_body = message.body
    run = workspace.workspace_content_expiry_runs.create!(cutoff_at: 1.day.from_now)

    purger = ->(*) { raise SupermemoryEngine::Unavailable, "offline" }
    WorkspaceContentExpiry.perform!(run:, object_purger: purger)

    assert run.reload.failed?
    assert_equal "unavailable", run.failure_code
    assert_equal original_body, message.reload.body
    audit = workspace.audit_events.order(:id).last
    assert_equal "workspace.content_expiry_failed", audit.action
    assert_equal({ "failure_code" => "unavailable" }, audit.metadata)
  end

  test "expiry makes a pending index entry terminal based on memory age" do
    workspace = workspaces(:acme_support)
    memory = workspace.memory_records.create!(
      memory_type: :episodic, scope_kind: :workspace, topic: "old-memory", content: "Private old memory",
      authority: :source_record, origin_kind: :system, source_reference: "test://old-memory",
      source_digest: Digest::SHA256.hexdigest("old-memory"), observed_at: 3.days.ago,
      valid_from: 3.days.ago, confidence: 1, retention_policy: :indefinite
    )
    entry = workspace.memory_index_entries.create!(memory_record: memory)
    run = workspace.workspace_content_expiry_runs.create!(cutoff_at: 2.days.ago)

    WorkspaceContentExpiry.perform!(run:, object_purger: ->(*) { })

    assert entry.reload.failed?
    assert_equal "retention_expired", entry.failure_code
    engine = Object.new
    engine.define_singleton_method(:index) { |**| flunk "expired memory must never be indexed" }
    MemoryIndexer.perform!(entry:, engine:)
  end

  test "repeat expiry neither rewrites nor recounts a terminal index entry" do
    organization = Organization.create!(name: "Repeat expiry", slug: "repeat-expiry")
    workspace = organization.workspaces.create!(name: "Subject", slug: "subject")
    memory = create_old_memory(workspace, "repeat-expiry")
    entry = workspace.memory_index_entries.create!(memory_record: memory)
    cutoff = 2.days.ago

    expire_workspace_content(workspace, cutoff)
    marker = 1.day.ago.change(usec: 123_456)
    set_index_entry_updated_at(entry, marker)
    expire_workspace_content(workspace, cutoff)

    assert entry.reload.failed?
    assert_equal "retention_expired", entry.failure_code
    assert_equal marker, entry.updated_at
  end

  test "expiry redacts schema v2 claims actions and blockers while preserving contract and audit lineage" do
    workspace = workspaces(:acme_support)
    artifact = create_v2_artifact(workspace)
    audit = AuditEvent.record!(
      action: "crew.artifact_published", source: :runner, workspace:, actor_kind: :system, subject: artifact,
      metadata: {
        "artifact_kind" => artifact.artifact_kind, "version" => artifact.version_number,
        "schema_version" => artifact.schema_version,
        "contract_version" => artifact.resolution_contract_version.version_number,
        "contract_result" => artifact.contract_result_state
      }
    )
    original_text = [
      "Typed customer fact", "Typed technical fact", "Send a private follow-up",
      "Unresolved private blocker", "Ask for the private record"
    ]

    expire_workspace_content(workspace, 1.day.from_now)
    artifact.reload

    assert_equal 2, artifact.schema_version
    assert_equal "blocked", artifact.contract_result_state
    assert artifact.resolution_contract_version
    assert artifact.contract_evaluated_at
    assert_equal [ "expired_claim_1", "expired_claim_2" ], artifact.material_claims.map { |claim| claim.fetch("key") }
    assert_equal %w[uncertain uncertain], artifact.material_claims.map { |claim| claim.fetch("state") }
    assert artifact.material_claims.all? { |claim| claim.fetch("text") == "[Expired by retention policy]" }
    assert artifact.material_claims.flat_map { |claim| claim.fetch("evidence") }.all? do |evidence|
      evidence.fetch("status") == "expired" && evidence.fetch("locator").start_with?("retention-expired://crew-artifacts/")
    end
    assert_empty artifact.proposed_actions
    assert artifact.contract_blockers.all? do |blocker|
      blocker.fetch("claim_key").nil? && blocker.fetch("message") == "[Expired by retention policy]" &&
        blocker.fetch("remediation") == "[Expired by retention policy]"
    end
    assert artifact.valid?
    assert AuditEvent.exists?(audit.id)
    retained = artifact.attributes.slice(
      "body", "uncertainty", "citations", "conflicts", "change_requests", "required_facts",
      "material_claims", "proposed_actions", "contract_blockers"
    ).to_json
    original_text.each { |text| refute_includes retained, text }
  end

  test "expiry redacts generated text while preserving draft and delivery provenance" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    support_case = create_support_case(workspace:, membership: owner)
    add_inbound_message(support_case, body: "Private provenance evidence")
    inbox = workspace.shared_email_inboxes.create!(
      name: "Retention provenance", email_address: "retention@example.com", credential_key: "retention"
    )
    thread = workspace.email_threads.create!(
      shared_email_inbox: inbox, conversation: support_case.conversation,
      thread_key: "retention-provenance@example.com"
    )
    artifact = create_draft_artifact(
      workspace:, support_case:, membership: owner,
      body: "Private generated answer", result_state: "blocked"
    )
    generated_digest = Digest::SHA256.hexdigest(artifact.body)
    draft = EmailDraftWorkflow.save!(
      workspace:, support_case:, membership: owner, body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )
    edited_at = Time.zone.parse("2026-08-27 14:00:00 UTC")
    draft = travel_to(edited_at) do
      EmailDraftWorkflow.save!(
        workspace:, support_case:, membership: owner, body: "Private human-qualified answer",
        expected_lock_version: draft.lock_version.to_s, source_crew_artifact_id: artifact.id
      )
    end
    delivery = workspace.outbound_email_deliveries.create!(
      email_draft: draft, shared_email_inbox: inbox, email_thread: thread,
      conversation: support_case.conversation, actor_membership: owner, actor_user: owner.user,
      idempotency_key: "retention-provenance", message_id: "retention@navishai.local",
      from_address: inbox.email_address, to_address: "customer@example.com", subject: "Private final",
      body: draft.body, started_at: Time.current, **HumanDraftProvenance.delivery_attributes(draft)
    )

    expire_workspace_content(workspace, 1.day.from_now)
    artifact.reload
    draft.reload
    delivery.reload

    assert_equal "[Expired by retention policy]", artifact.body
    assert_equal "[Expired by retention policy]", draft.body
    assert_equal "[Expired by retention policy]", delivery.body
    [ draft, delivery ].each do |record|
      assert_equal artifact, record.source_crew_artifact
      assert_equal generated_digest, record.generated_body_digest
      assert_equal "blocked", record.generated_contract_result_state
      assert_equal owner, record.human_edited_by_membership
      assert_equal owner.user, record.human_edited_by_user
      assert_equal edited_at, record.human_edited_at
      assert record.valid?
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      OutboundEmailDelivery.transaction(requires_new: true) do
        OutboundEmailDelivery.where(id: delivery.id).update_all(generated_body_digest: "0" * 64)
      end
    end
  end

  private
    def create_v2_artifact(workspace)
      owner = memberships(:owner_support)
      approve_scripted_runtime(workspace:, membership: owner)
      CrewConfiguration.install_defaults!(workspace:)
      family = ResolutionContractConfiguration.install_defaults!(workspace:)
        .find_by!(family_key: "support_resolution")
      support_case = create_support_case
      message = add_inbound_message(support_case, body: "Private source evidence")
      profile = workspace.agent_profiles.find_by!(role_key: "support_investigator")
      task = CrewWork.create!(
        workspace:, membership: owner, scope: support_case, profile:, title: "Private task",
        input_context: "Use private evidence.", expected_output: "Return typed private claims."
      )
      run = ExecutionLedger.new(workspace:).prepare!(task:, request_key: "expiry:v2:#{task.id}")
      locator = "conversation://#{support_case.conversation_id}/messages/#{message.id}"
      observed_at = message.occurred_at.iso8601(6)
      fresh_until = (message.occurred_at + 365.days).iso8601(6)
      evidence = ->(kind) {
        [ {
          "kind" => kind, "locator" => locator, "status" => "available", "observed_at" => observed_at,
          "valid_until" => nil, "fresh_until" => fresh_until
        } ]
      }
      workspace.crew_artifacts.create!(
        crew_task: task, execution_run: run, version_number: 1, schema_version: 2,
        artifact_kind: "investigation", body: "Private artifact body", uncertainty: "Private uncertainty",
        citations: [ { "kind" => "conversation", "locator" => locator, "label" => "Private citation" } ],
        conflicts: [ { "summary" => "Private conflict", "details" => "Private conflict detail", "severity" => "warning" } ],
        change_requests: [ "Private change request" ], payload_digest: Digest::SHA256.hexdigest("private-v2"),
        resolution_contract_version: family.current_version,
        required_facts: %w[customer_fact technical_fact],
        material_claims: [
          {
            "key" => "customer_fact", "category" => "customer_account_fact", "text" => "Typed customer fact",
            "state" => "supported", "evidence" => evidence.call("conversation")
          },
          {
            "key" => "technical_fact", "category" => "product_technical_fact", "text" => "Typed technical fact",
            "state" => "uncertain", "evidence" => evidence.call("conversation")
          }
        ],
        proposed_actions: [ "Send a private follow-up" ],
        policy_checks: ResolutionContractVersion::REVIEW_CHECKS.keys.sort.map do |check|
          { "check" => check, "status" => check == "claims_grounded" ? "failed" : "passed" }
        end,
        contract_result_state: "blocked",
        contract_blockers: [ {
          "code" => "claim_uncertain", "claim_key" => "technical_fact", "message" => "Unresolved private blocker",
          "remediation" => "Ask for the private record", "severity" => "blocking"
        } ],
        contract_evaluated_at: Time.current
      )
    end

    def create_old_memory(workspace, key)
      workspace.memory_records.create!(
        memory_type: :episodic, scope_kind: :workspace, topic: "old-memory", content: "Private old memory",
        authority: :source_record, origin_kind: :system, source_reference: "test://#{key}",
        source_digest: Digest::SHA256.hexdigest(key), observed_at: 3.days.ago,
        valid_from: 3.days.ago, confidence: 1, retention_policy: :indefinite
      )
    end

    def expire_workspace_content(workspace, cutoff)
      connection = ActiveRecord::Base.connection
      connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      connection.select_value(
        "SELECT expire_workspace_content(#{workspace.id}, #{connection.quote(cutoff)})"
      ).to_i
    ensure
      begin
        connection&.execute("SET CONSTRAINTS ALL DEFERRED")
      rescue ActiveRecord::StatementInvalid
        nil
      end
    end

    def set_index_entry_updated_at(entry, timestamp)
      connection = ActiveRecord::Base.connection
      connection.execute("ALTER TABLE memory_index_entries DISABLE TRIGGER USER")
      connection.execute(
        "UPDATE memory_index_entries SET updated_at = #{connection.quote(timestamp)} WHERE id = #{entry.id}"
      )
    ensure
      connection&.execute("ALTER TABLE memory_index_entries ENABLE TRIGGER USER")
    end
end
