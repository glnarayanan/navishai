require "test_helper"

class SupportQualityReadoutTest < ActiveSupport::TestCase
  class RecordingTransport
    def deliver!(**)
      true
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
  end

  test "an empty workspace reports zeros and no attention" do
    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 0, metric(readout, "open_cases").value
    assert_equal 0, metric(readout, "first_response_breaches").value
    assert_equal 0, metric(readout, "resolution_breaches").value
    assert_equal 0, metric(readout, "reopened_90d").value
    assert_equal 0, metric(readout, "without_proof_90d").value
    assert_equal 0, metric(readout, "proofed_90d").value
    assert_equal 0, metric(readout, "blocked_drafts").value
    assert_not readout.attention?
    assert_empty readout.breached_cases
    assert_empty readout.unproofed_accounts
    assert_empty readout.blocked_drafts
  end

  test "counts an open case without treating volume as attention" do
    create_support_case(subject: "Open quality case")

    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 1, metric(readout, "open_cases").value
    assert_equal "neutral", metric(readout, "open_cases").tone
    assert_not readout.attention?
  end

  test "counts first-response and resolution breaches on open cases" do
    install_sla_policy
    support_case = create_support_case(subject: "Breached quality case")
    support_case.case_sla.update!(first_response_status: "breached", resolution_status: "breached")

    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 1, metric(readout, "first_response_breaches").value
    assert_equal 1, metric(readout, "resolution_breaches").value
    assert_equal "attention", metric(readout, "first_response_breaches").tone
    assert readout.attention?
    row = readout.breached_cases.sole
    assert_equal "Breached quality case", row.title
    assert_match(/first response breached/, row.detail)
    assert_match(/resolution breached/, row.detail)
    assert_equal [ @workspace, support_case ], row.path
  end

  test "sums latest unproofed and reopen signals and lists unproofed accounts" do
    event_time = Time.current.change(usec: 0)
    account = accounts(:acme)
    contact = @workspace.contacts.create!(account:, name: "Quality lifecycle contact")
    first_case = create_support_case(subject: "Quality outage one", contact:)
    second_case = create_support_case(subject: "Quality outage two", contact:)
    first_case.status_changes.create!(
      workspace: @workspace, from_status: "resolved", to_status: "investigating",
      actor_kind: "system", source: "integration", reason: "Customer replied", occurred_at: event_time - 2.days
    )
    [ first_case, second_case ].each do |support_case|
      support_case.status_changes.create!(
        workspace: @workspace, from_status: "awaiting_human_review", to_status: "resolved",
        actor_kind: "user", actor: @owner.user, source: "web", reason: "Human confirmed",
        occurred_at: event_time - 1.day
      )
    end
    create_draft_artifact(
      workspace: @workspace, support_case: first_case, membership: @owner,
      body: "Proofed quality resolution", result_state: "complete"
    )
    AccountHealth.recalculate!(
      workspace: @workspace, account:, trigger_kind: "human_request", membership: @owner,
      at: 1.second.from_now.change(usec: 0)
    )

    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 1, metric(readout, "reopened_90d").value
    assert_equal 1, metric(readout, "without_proof_90d").value
    assert_equal 1, metric(readout, "proofed_90d").value
    assert_equal "healthy", metric(readout, "proofed_90d").tone
    assert readout.attention?
    row = readout.unproofed_accounts.sole
    assert_equal account.name, row.title
    assert_match(/1 resolution without contract proof/, row.detail)
    assert_equal [ @workspace, account ], row.path
  end

  test "lists current blocked resolution drafts and ignores complete drafts" do
    support_case = create_support_case(subject: "Blocked quality draft")
    create_draft_artifact(
      workspace: @workspace, support_case:, membership: @owner,
      body: "Blocked quality answer", result_state: "blocked"
    )
    complete_case = create_support_case(subject: "Complete quality draft")
    create_draft_artifact(
      workspace: @workspace, support_case: complete_case, membership: @owner,
      body: "Complete quality answer", result_state: "complete"
    )

    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 1, metric(readout, "blocked_drafts").value
    row = readout.blocked_drafts.sole
    assert_equal "Blocked quality draft", row.title
    assert_match(/blocked/i, row.detail)
    assert_equal [ @workspace, support_case ], row.path
  end

  test "ignores foreign Workspace cases, SLA clocks, health, and drafts" do
    install_sla_policy
    local_case = create_support_case(subject: "Local quality case")
    local_case.case_sla.update!(first_response_status: "breached")

    foreign = workspaces(:beta_support)
    foreign_owner = memberships(:outsider_beta)
    calendar = ServiceCalendar.create!(
      workspace: foreign, name: "Foreign hours", time_zone: "UTC",
      weekly_hours: %w[monday tuesday wednesday thursday friday].index_with { [ [ "09:00", "17:00" ] ] }
    )
    SlaPolicy.create!(
      workspace: foreign, service_calendar: calendar, name: "Foreign normal",
      priority: :normal, first_response_minutes: 120, resolution_minutes: 480, warning_percent: 75
    )
    foreign_case = create_support_case(
      subject: "Foreign quality case", workspace: foreign, contact: contacts(:bob), membership: foreign_owner
    )
    foreign_case.case_sla.update!(first_response_status: "breached", resolution_status: "breached")
    create_draft_artifact(
      workspace: foreign, support_case: foreign_case, membership: foreign_owner,
      body: "Foreign blocked draft", result_state: "blocked"
    )
    AccountHealth.recalculate!(
      workspace: foreign, account: accounts(:beta), trigger_kind: "human_request",
      membership: foreign_owner
    )

    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 1, metric(readout, "open_cases").value
    assert_equal 1, metric(readout, "first_response_breaches").value
    assert_equal 0, metric(readout, "resolution_breaches").value
    assert_equal 0, metric(readout, "blocked_drafts").value
    assert_equal [ "Local quality case" ], readout.breached_cases.map(&:title)
    assert_empty readout.unproofed_accounts
    assert_empty readout.blocked_drafts
    readout.windows.each do |window|
      assert_equal 0, window_metric(window, "blocked_drafts").value
      assert_empty window.rows
    end
  end

  test "uses fixed windows, final draft revisions, and explicit unknown-cost coverage" do
    now = Time.utc(2026, 9, 14, 12)
    first = travel_to(now - 8.days) do
      create_draft_artifact(
        workspace: @workspace, support_case: create_support_case(subject: "Revision lineage"), membership: @owner,
        body: "First revision", result_state: "blocked"
      )
    end
    retry_run = ExecutionLedger.new(workspace: @workspace).prepare!(
      task: first.crew_task, request_key: "quality-readout-revision-#{SecureRandom.uuid}"
    )
    final = first.dup
    final.assign_attributes(
      artifact_key: SecureRandom.uuid, execution_run: retry_run, supersedes_artifact: first,
      version_number: 2, body: "Grounded revision", contract_result_state: "complete",
      contract_blockers: [], contract_evaluated_at: now - 2.days,
      payload_digest: Digest::SHA256.hexdigest("quality-readout-final")
    )
    final.save!
    fail_run(retry_run, at: now - 1.day)

    readout = SupportQualityReadout.build(workspace: @workspace, now:)
    week = readout.windows.find { |window| window.days == 7 }
    month = readout.windows.find { |window| window.days == 30 }

    assert_equal "Last 7 days", week.label
    assert_equal 1, window_metric(week, "completed_drafts").value
    assert_equal 0, window_metric(week, "blocked_drafts").value
    assert_equal "Unknown", window_metric(week, "observed_usage").value
    assert_match(/Input reported for 0 of 1 terminal support runs; output reported for 0 of 1/, window_metric(week, "observed_usage").detail)
    assert_equal "Unknown", window_metric(week, "known_cost").value
    assert_match(/0 of 1 terminal support runs; 1 have no known amount/, window_metric(week, "known_cost").detail)
    assert_equal 1, window_metric(month, "completed_drafts").value
    assert_equal 0, window_metric(month, "blocked_drafts").value
    assert_match(/superseded draft artifacts are excluded/, week.methodology)
    assert week.rows.any? { |row| row.title.start_with?("Run ") && row.path.end_with?("/run/#{retry_run.id}") }
  end

  test "distinguishes reported zero usage from unknown usage and retains micro cost precision" do
    now = Time.utc(2026, 9, 14, 12)
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: create_support_case(subject: "Micro cost quality run"), membership: @owner,
      body: "A draft with a reported micro cost", result_state: "complete"
    )
    run = ExecutionLedger.new(workspace: @workspace).prepare!(
      task: artifact.crew_task, request_key: "quality-readout-micro-cost-#{SecureRandom.uuid}"
    )
    fail_run(run, at: now - 1.minute, usage: { input_units: 0, output_units: 0, amount_micros: 1, currency: "USD" })

    week = SupportQualityReadout.build(workspace: @workspace, now:).windows.find { |window| window.days == 7 }

    assert_equal "0 in / 0 out", window_metric(week, "observed_usage").value
    assert_match(/Input reported for 1 of 1 terminal support runs; output reported for 1 of 1/, window_metric(week, "observed_usage").detail)
    assert_equal "0.000001 USD", window_metric(week, "known_cost").value
    assert_match(/Known amount for 1 of 1 terminal support runs; 0 have no known amount/, window_metric(week, "known_cost").detail)
  end

  test "keeps completed and blocked draft drilldowns alongside structured blocker-code rows" do
    now = Time.utc(2026, 9, 14, 12)
    support_case = email_support_case(workspace: @workspace, membership: @owner, subject: "Attributable local case", received_at: now - 3.hours)
    support_case.status_changes.create!(
      workspace: @workspace, from_status: "investigating", to_status: "draft_ready", actor_kind: "user", actor: @owner.user,
      source: "web", reason: "Draft is ready", occurred_at: now - 2.hours
    )
    first = create_draft_artifact(workspace: @workspace, support_case:, membership: @owner, body: "First generated answer", result_state: "complete")
    retry_run = ExecutionLedger.new(workspace: @workspace).prepare!(task: first.crew_task, request_key: "quality-send-retry-#{SecureRandom.uuid}")
    final = revise_draft(first, retry_run, body: "Revised generated answer", result_state: "complete", evaluated_at: now - 90.minutes)
    create_quality_review(target: final, created_at: now - 80.minutes)
    sent_first = send_email_artifact(workspace: @workspace, membership: @owner, support_case:, artifact: first, sent_at: now - 60.minutes)
    receive_email_follow_up(workspace: @workspace, support_case:, received_at: now - 45.minutes)
    sent_final = send_email_artifact(workspace: @workspace, membership: @owner, support_case:, artifact: final, sent_at: now - 30.minutes)

    blocked_case = create_support_case(workspace: @workspace, membership: @owner, subject: "Structured blocker")
    blocked = travel_to(now - 20.minutes) do
      create_draft_artifact(workspace: @workspace, support_case: blocked_case, membership: @owner, result_state: "blocked")
    end
    unstructured_case = create_support_case(workspace: @workspace, membership: @owner, subject: "Unstructured blocker")
    unstructured = travel_to(now - 10.minutes) do
      create_draft_artifact(
        workspace: @workspace, support_case: unstructured_case, membership: @owner,
        result_state: "blocked", contract_blockers: []
      )
    end

    foreign = workspaces(:beta_support)
    foreign_owner = memberships(:outsider_beta)
    foreign_case = email_support_case(workspace: foreign, membership: foreign_owner, subject: "Foreign sent case", received_at: now - 3.hours)
    foreign_artifact = create_draft_artifact(workspace: foreign, support_case: foreign_case, membership: foreign_owner, result_state: "complete")
    send_email_artifact(workspace: foreign, membership: foreign_owner, support_case: foreign_case, artifact: foreign_artifact, sent_at: now - 30.minutes)

    week = SupportQualityReadout.build(workspace: @workspace, now:).windows.find { |window| window.days == 7 }

    assert_equal 1, window_metric(week, "human_sent_lineages").value
    assert_equal "1h 0m", window_metric(week, "intake_to_draft_ready").value
    assert_equal "1h 30m", window_metric(week, "draft_ready_to_human_send").value
    assert_equal 2, window_metric(week, "blocked_drafts").value
    assert_equal 1, window_metric(week, "changes_requested").value
    assert_equal "claim_uncertain × 1", window_metric(week, "contract_failure_reasons").value
    assert week.rows.any? { |row| row.artifact == final && row.detail == "Completed draft" }
    assert week.rows.any? { |row| row.artifact == blocked && row.detail == "Blocked draft" }
    assert week.rows.any? { |row| row.artifact == blocked && row.detail == "Blocked draft · claim_uncertain" }
    assert week.rows.any? { |row| row.artifact == unstructured && row.detail == "Blocked draft" }
    assert week.rows.any? { |row| row.artifact == final && row.detail == "Review requested changes" }
    assert week.rows.any? { |row| row.artifact == sent_final.source_crew_artifact && row.detail.match?(/Human sent/) }
    refute week.rows.any? { |row| row.title == "Foreign sent case" }
    assert_equal final.id, sent_final.source_crew_artifact_id
    assert_equal first.id, sent_first.source_crew_artifact_id
    assert_match(/deliveries from any revision of one draft lineage collapse to one lineage/, week.methodology)
  end

  test "caps evidence independently so completed drafts cannot hide later quality categories" do
    now = Time.utc(2026, 9, 14, 12)
    completed = SupportQualityReadout::DETAIL_LIMIT + 1

    completed.times do |index|
      travel_to(now - 2.hours + index.seconds) do
        create_draft_artifact(
          workspace: @workspace,
          support_case: create_support_case(subject: "Completed evidence #{index}"),
          membership: @owner,
          body: "Completed answer #{index}",
          result_state: "complete"
        )
      end
    end

    blocked_case = create_support_case(subject: "Blocked after completed evidence")
    blocked = travel_to(now - 30.minutes) do
      create_draft_artifact(
        workspace: @workspace, support_case: blocked_case, membership: @owner,
        body: "Blocked answer", result_state: "blocked"
      )
    end
    create_quality_review(target: blocked, created_at: now - 20.minutes)

    week = SupportQualityReadout.build(workspace: @workspace, now:).windows.find { |window| window.days == 7 }

    assert_equal completed, window_metric(week, "completed_drafts").value
    assert_match(/20 linked records shown; 1 omitted by the per-category detail limit/, window_metric(week, "completed_drafts").detail)
    assert_equal 1, window_metric(week, "blocked_drafts").value
    assert_equal 1, window_metric(week, "changes_requested").value
    assert week.rows.any? { |row| row.artifact == blocked && row.detail == "Blocked draft" }
    assert week.rows.any? { |row| row.artifact == blocked && row.detail == "Blocked draft · claim_uncertain" }
    assert week.rows.any? { |row| row.artifact == blocked && row.detail == "Review requested changes" }
    assert_operator week.rows.count { |row| row.detail == "Completed draft" }, :<=, SupportQualityReadout::DETAIL_LIMIT
  end

  private
    def metric(readout, key)
      readout.metrics.find { |item| item.key == key }
    end

    def window_metric(window, key)
      window.metrics.find { |item| item.key == key }
    end

    def revise_draft(artifact, run, body:, result_state:, evaluated_at:)
      artifact.dup.tap do |revision|
        revision.assign_attributes(
          artifact_key: SecureRandom.uuid, execution_run: run, supersedes_artifact: artifact,
          version_number: artifact.version_number + 1, body:, contract_result_state: result_state,
          contract_blockers: [], contract_evaluated_at: evaluated_at,
          payload_digest: Digest::SHA256.hexdigest("quality-revision-#{SecureRandom.uuid}")
        )
        revision.save!
      end
    end

    def create_quality_review(target:, created_at:)
      profile = @workspace.agent_profiles.find_by!(role_key: "support_reviewer")
      task = CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: target.crew_task.support_case, profile:,
        title: "Quality review source #{SecureRandom.hex(4)}", input_context: "Review this draft.", expected_output: "Record review."
      )
      run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: "quality-review-#{SecureRandom.uuid}")
      target.dup.tap do |review|
        review.assign_attributes(
          artifact_key: SecureRandom.uuid, crew_task: task, execution_run: run, artifact_kind: "quality_review",
          version_number: 1, supersedes_artifact: nil, target_artifact: target, review_outcome: "changes_requested",
          body: "Changes are required", payload_digest: Digest::SHA256.hexdigest("quality-review-#{SecureRandom.uuid}"),
          created_at:, updated_at: created_at
        )
        review.save!
      end
    end

    def email_support_case(workspace:, membership:, subject:, received_at:)
      inbox = workspace.shared_email_inboxes.create!(name: "Quality inbox #{SecureRandom.hex(4)}", email_address: "quality-#{SecureRandom.hex(4)}@example.com", credential_key: "quality_#{SecureRandom.hex(8)}")
      travel_to(received_at) do
        SharedEmailIntake.receive!(
          inbox:,
          raw_email: [
            "From: Customer <customer@example.net>", "To: #{inbox.email_address}", "Date: #{received_at.rfc2822}",
            "Subject: #{subject}", "Message-ID: <#{SecureRandom.uuid}@example.net>", "Content-Type: text/plain; charset=UTF-8", "", "Please help"
          ].join("\r\n"),
          received_at:
        ).conversation.support_case
      end
    end

    def send_email_artifact(workspace:, membership:, support_case:, artifact:, sent_at:)
      current_draft = support_case.reload.email_draft
      draft = EmailDraftWorkflow.save!(
        workspace:, support_case:, membership:, body: artifact.body,
        expected_lock_version: current_draft&.lock_version&.to_s || "new",
        source_crew_artifact_id: artifact.id, adopt_source: true
      )
      preview = HumanEmailSend.recipient_preview(workspace:, support_case:)
      travel_to(sent_at) do
        Current.session = membership.user.sessions.create!(authentication_method: :local, expires_at: 12.hours.from_now)
        HumanEmailSend.send!(
          workspace:, support_case:, membership:, body: artifact.body, draft_version: draft.lock_version.to_s,
          idempotency_key: "quality-delivery-#{SecureRandom.uuid}", source_crew_artifact_id: artifact.id,
          expected_recipient_address: preview.address, expected_inbound_message_id: preview.inbound_message_id,
          transport: RecordingTransport.new
        )
      ensure
        Current.session = nil
      end
    end

    def receive_email_follow_up(workspace:, support_case:, received_at:)
      thread = workspace.email_threads.find_by!(conversation: support_case.conversation)
      in_reply_to = thread.email_message_links.order(:id).last.message_id
      SharedEmailIntake.receive!(
        inbox: thread.shared_email_inbox,
        raw_email: [
          "From: Customer <customer@example.net>", "To: #{thread.shared_email_inbox.email_address}",
          "Date: #{received_at.rfc2822}", "Subject: #{support_case.conversation.subject}",
          "Message-ID: <#{SecureRandom.uuid}@example.net>", "In-Reply-To: #{in_reply_to}",
          "Content-Type: text/plain; charset=UTF-8", "", "I still need help"
        ].join("\r\n"),
        received_at:
      )
    end

    def fail_run(run, at:, usage: nil)
      ledger = ExecutionLedger.new(workspace: @workspace)
      events = [
        [ "run.admitted", { workspace_key: @workspace.runner_key, task_key: run.crew_task.task_key, attempt: run.attempt_number } ],
        [ "run.started", { adapter: "scripted", scenario: "quality readout", attempt: run.attempt_number } ],
        *(usage ? [ [ "usage.observed", usage ] ] : []),
        [ "run.failed", { code: "scripted_failure", retryable: false } ]
      ]
      travel_to(at) do
        events.each_with_index do |(event_type, data), index|
          ledger.ingest!(event: {
            "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
            "sequence" => index + 1, "event_type" => event_type,
            "occurred_at" => (at + index.seconds).iso8601(6), "data" => data.stringify_keys
          })
        end
      end
    end

    def install_sla_policy
      calendar = ServiceCalendar.create!(
        workspace: @workspace, name: "Quality hours", time_zone: "UTC",
        weekly_hours: %w[monday tuesday wednesday thursday friday].index_with { [ [ "09:00", "17:00" ] ] }
      )
      SlaPolicy.create!(
        workspace: @workspace, service_calendar: calendar, name: "Quality normal",
        priority: :normal, first_response_minutes: 120, resolution_minutes: 480, warning_percent: 75
      )
    end
end
