require "test_helper"

class AccountHealthTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @account = @workspace.accounts.create!(name: "Renewal Test")
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @at = Time.zone.parse("2026-08-24 12:00:00")
  end

  test "imports typed CSV inputs idempotently and calculates an explainable renewal risk snapshot" do
    content = <<~CSV
      source_id,source_namespace,observed_at,account_name,account_domain,contact_name,contact_email,renewal_on,contract_value,active_users,licensed_seats
      renewal-1,billing.csv,2026-08-20T12:00:00Z,Imported Renewal Test,,Alice,alice@renewal.example,2026-09-13,120000,10,100
    CSV

    assert_equal 1, AccountDataImport.import_csv!(workspace: @workspace, membership: @owner, content:)
    account = @workspace.accounts.find_by!(name: "Imported Renewal Test")
    assessment = account.current_health_assessment

    assert_equal 4, account.health_inputs.count
    assert_equal [ "billing.csv" ], account.health_inputs.distinct.pluck(:source_namespace)
    assert account.health_inputs.all? { |input| input.observed_at == Time.zone.parse("2026-08-20 12:00:00") }
    assert_equal 40, assessment.score
    assert_equal "at_risk", assessment.risk_level
    assert_not assessment.material_change?
    assert_equal %w[contract_value customer_inactivity_days internal_notes_90d open_cases proofed_resolutions_90d recurring_issue_tags_90d renewal_on reopened_cases_90d resolutions_without_proof_90d seat_utilization_percent sla_breaches],
      assessment.signals.pluck(:signal_key).sort
    assert_equal 25, assessment.signals.find_by!(signal_key: "renewal_on").risk_points
    assert_equal "health://assessments/#{assessment.id}/signals/renewal_on",
      assessment.signals.find_by!(signal_key: "renewal_on").citation_uri
    assert_equal "renewal_window", assessment.risk_investigation.trigger_kind

    assert_equal 1, AccountDataImport.import_csv!(workspace: @workspace, membership: @owner, content:)
    assert_equal 4, account.health_inputs.count
    assert_equal 2, account.health_assessments.count
    assert AuditEvent.exists?(action: "account.data_imported", actor: @owner.user)
    assert AuditEvent.exists?(action: "account.created", actor: @owner.user, subject_type: "Account", subject_id: account.id)
  end

  test "clamps combined score at zero and blocks truncating retained snapshots" do
    signals = [ AccountHealth::Signal.new(
      signal_key: "open_cases", value_kind: "number", numeric_value: 10, date_value: nil,
      weight: 0, risk_points: 0, source_kind: "support_cases", source_locator: "account://#{@account.id}/cases",
      range_starts_at: nil, range_ends_at: @at
    ), AccountHealth::Signal.new(
      signal_key: "sla_breaches", value_kind: "number", numeric_value: 10, date_value: nil,
      weight: 0, risk_points: 0, source_kind: "sla", source_locator: "account://#{@account.id}/slas",
      range_starts_at: nil, range_ends_at: @at
    ), AccountHealth::Signal.new(
      signal_key: "customer_inactivity_days", value_kind: "number", numeric_value: 90, date_value: nil,
      weight: 0, risk_points: 0, source_kind: "conversation", source_locator: "account://#{@account.id}/conversations",
      range_starts_at: nil, range_ends_at: @at
    ), AccountHealth::Signal.new(
      signal_key: "renewal_on", value_kind: "date", numeric_value: nil, date_value: @at.to_date + 10,
      weight: 0, risk_points: 0, source_kind: "account_input", source_locator: "account://#{@account.id}/renewal",
      range_starts_at: nil, range_ends_at: @at
    ), AccountHealth::Signal.new(
      signal_key: "seat_utilization_percent", value_kind: "number", numeric_value: 10, date_value: nil,
      weight: 0, risk_points: 0, source_kind: "account_input", source_locator: "account://#{@account.id}/seats",
      range_starts_at: nil, range_ends_at: @at
    ) ]
    service = AccountHealth.new(workspace: @workspace, membership: @owner)
    service.define_singleton_method(:build_signals) { |_account, _at| signals }
    assessment = service.recalculate!(account: @account, trigger_kind: "human_request", at: @at)
    assert_equal 0, assessment.score

    assert_raises(ActiveRecord::StatementInvalid) do
      AccountHealthSignal.transaction(requires_new: true) { AccountHealthSignal.connection.execute("TRUNCATE account_health_signals") }
    end
    assert_equal 5, assessment.signals.count
  end

  test "material changes and human requests open retained risk reviews while schedules remain callable" do
    import_api("baseline", renewal_on: "2027-02-20", active_users: 90, licensed_seats: 100)
    first = @account.reload.current_health_assessment
    assert_equal 75, first.score
    assert_equal "healthy", first.risk_level
    assert_nil first.risk_investigation

    import_api("drop", renewal_on: "2026-09-10", active_users: 10, licensed_seats: 100)
    changed = @account.reload.current_health_assessment
    assert changed.material_change?
    assert_equal "at_risk", changed.risk_level
    assert_equal "renewal_window", changed.risk_investigation.trigger_kind

    scheduled = AccountHealth.recalculate_due!(workspace: @workspace, at: @at)
      .find { |assessment| assessment.account_id == @account.id }
    assert_equal "renewal_window", scheduled.trigger_kind
    assert_nil scheduled.risk_investigation
    assert_equal 1, @account.risk_investigations.where(status: %w[detected investigating]).count

    active_review = AccountRiskWorkflow.start!(workspace: @workspace, membership: @owner,
      investigation: @account.risk_investigations.first)
    task = active_review.crew_task
    CrewWork.apply!(workspace: @workspace, membership: @owner, task:, command: :start,
      expected_sequence: task.current_event.sequence_number)
    CrewWork.apply!(workspace: @workspace, membership: @owner, task:, command: :request_review,
      expected_sequence: task.reload.current_event.sequence_number, attributes: { body: "Review complete." })
    CrewWork.apply!(workspace: @workspace, membership: @owner, task:, command: :review,
      expected_sequence: task.reload.current_event.sequence_number,
      attributes: { review_outcome: "approved", body: "Evidence checked." })
    AccountRiskWorkflow.resolve!(workspace: @workspace, membership: @owner,
      investigation: @account.risk_investigations.first)
    requested = AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: @owner, at: @at)
    assert_equal "human_request", requested.risk_investigation.trigger_kind
  end

  test "starts a Customer Success crew investigation and preserves workspace boundaries" do
    import_api("risk", renewal_on: "2026-09-10")
    investigation = @account.reload.current_health_assessment.risk_investigation

    result = AccountRiskWorkflow.start!(workspace: @workspace, membership: @owner, investigation:)
    assert result.investigating?
    assert_equal "risk_investigator", result.crew_task.assigned_agent_profile.role_key
    assert_equal @account, result.crew_task.account
    assert_includes result.crew_task.input_context, result.account_health_assessment.id.to_s
    assert AuditEvent.exists?(action: "account.risk_started", actor: @owner.user, subject_id: result.id)

    assert_raises(ActiveRecord::RecordNotFound) do
      AccountRiskWorkflow.start!(workspace: workspaces(:beta_support), membership: memberships(:outsider_beta), investigation:)
    end
  end

  test "rejects changed idempotency sources and database mutation of snapshots" do
    import_api("stable", renewal_on: "2027-01-01")
    assert_raises(AccountDataImport::InvalidImport) { import_api("stable", renewal_on: "2027-02-01") }

    input = @account.health_inputs.first
    assessment = @account.health_assessments.first
    signal = assessment.signals.first
    assert_raises(ActiveRecord::StatementInvalid) do
      AccountHealthInput.transaction(requires_new: true) { AccountHealthInput.where(id: input.id).update_all(date_value: Date.new(2027, 3, 1)) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      AccountHealthAssessment.transaction(requires_new: true) { AccountHealthAssessment.where(id: assessment.id).update_all(score: 100) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      AccountHealthSignal.transaction(requires_new: true) { signal.delete }
    end
  end

  test "accepts bounded source metadata and appends explicit correction lineage" do
    observed_at = 2.days.ago.change(usec: 0)
    valid_from = 3.days.ago.change(usec: 0)
    valid_until = 30.days.from_now.change(usec: 0)
    baseline = {
      source_id: "crm-renewal-1", source_namespace: "crm.accounts",
      observed_at: observed_at.iso8601, valid_from: valid_from.iso8601, valid_until: valid_until.iso8601,
      account_name: @account.name, renewal_on: "2027-01-15"
    }

    assert_equal 1, AccountDataImport.import_api!(workspace: @workspace, membership: @owner, rows: [ baseline ])
    assert_equal 1, AccountDataImport.import_api!(workspace: @workspace, membership: @owner, rows: [ baseline ])
    original = @account.health_inputs.find_by!(source_key: "crm-renewal-1")
    assert_equal "crm.accounts", original.source_namespace
    assert_equal observed_at, original.observed_at
    assert_equal valid_from, original.valid_from
    assert_equal valid_until, original.valid_until
    assert_match(/\A[0-9a-f]{64}\z/, original.source_digest)

    correction = baseline.merge(
      source_id: "crm-renewal-2", corrects_source_id: "crm-renewal-1",
      observed_at: 1.day.ago.change(usec: 0).iso8601, renewal_on: "2027-02-15"
    )
    AccountDataImport.import_api!(workspace: @workspace, membership: @owner, rows: [ correction ])
    corrected = @account.health_inputs.find_by!(source_key: "crm-renewal-2")
    assert_equal original, corrected.corrects_input
    assert_equal [ corrected ], original.corrections
    assert_equal Date.new(2027, 2, 15), AccountHealth.latest_input(@account, "renewal_on").date_value
    assert_equal Date.new(2027, 1, 15), original.reload.date_value

    changed = baseline.merge(renewal_on: "2027-03-15")
    assert_raises(AccountDataImport::InvalidImport) do
      AccountDataImport.import_api!(workspace: @workspace, membership: @owner, rows: [ changed ])
    end
    assert_raises(AccountDataImport::InvalidImport) do
      AccountDataImport.import_api!(workspace: @workspace, membership: @owner, rows: [
        correction.merge(source_id: "bad-validity", valid_from: 1.day.from_now.iso8601,
          valid_until: 1.day.ago.iso8601)
      ])
    end
    assert_raises(AccountDataImport::InvalidImport) do
      AccountDataImport.import_api!(workspace: @workspace, membership: @owner, rows: [
        correction.merge(source_id: "foreign-correction", corrects_source_id: "missing")
      ])
    end
  end

  test "derives frozen support lifecycle evidence while new score rules stay disabled" do
    event_time = Time.current.change(usec: 0)
    contact = @workspace.contacts.create!(account: @account, name: "Lifecycle contact")
    first_case = create_support_case(subject: "Repeated outage one", contact:)
    second_case = create_support_case(subject: "Repeated outage two", contact:)
    tag = CaseWorkflow.create_tag!(workspace: @workspace, membership: @owner, name: "Repeated outage")
    CaseWorkflow.tag!(workspace: @workspace, support_case: first_case, membership: @owner, tag:)
    CaseWorkflow.tag!(workspace: @workspace, support_case: second_case, membership: @owner, tag:)
    reopened_change = first_case.status_changes.create!(
      workspace: @workspace, from_status: "resolved", to_status: "investigating",
      actor_kind: "system", source: "integration", reason: "Customer replied", occurred_at: event_time - 2.days
    )
    [ first_case, second_case ].each do |support_case|
      support_case.status_changes.create!(
        workspace: @workspace, from_status: "awaiting_human_review", to_status: "resolved",
        actor_kind: "user", actor: @owner.user, source: "web", reason: "Human confirmed", occurred_at: event_time - 1.day
      )
    end
    proof = create_draft_artifact(
      workspace: @workspace, support_case: first_case, membership: @owner,
      body: "Proofed resolution", result_state: "complete"
    )
    now = 1.second.from_now.change(usec: 0)

    assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request", membership: @owner, at: now
    )
    recurring = assessment.signals.find_by!(signal_key: "recurring_issue_tags_90d")
    reopened = assessment.signals.find_by!(signal_key: "reopened_cases_90d")
    unproofed = assessment.signals.find_by!(signal_key: "resolutions_without_proof_90d")
    proofed = assessment.signals.find_by!(signal_key: "proofed_resolutions_90d")

    assert_equal 2, recurring.numeric_value
    assert_equal 1, reopened.numeric_value
    assert_equal 1, unproofed.numeric_value
    assert_equal 1, proofed.numeric_value
    assert_equal 0, recurring.weight
    assert_equal 0, reopened.weight
    assert_equal 0, unproofed.weight
    assert_equal 0, proofed.weight
    assert_includes recurring.evidence_refs, { "kind" => "tag", "id" => tag.id }
    assert_includes reopened.evidence_refs,
      { "kind" => "support_case_status_change", "id" => reopened_change.id }
    assert_includes proofed.evidence_refs, { "kind" => "crew_artifact", "id" => proof.id }
    assert_equal 0, recurring.evidence_omitted_count
  end

  private
    def import_api(source_id, **values)
      AccountDataImport.import_api!(workspace: @workspace, membership: @owner, rows: [ {
        source_id:, observed_at: @at.iso8601, account_name: @account.name, **values
      } ])
    end
end
