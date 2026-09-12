require "test_helper"

class AccountWorkQueueTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @other = workspaces(:beta_support)
    @owner = memberships(:owner_support)
    @as_of = Date.new(2026, 9, 12)
    travel_to Time.zone.local(2026, 9, 12, 12)
    CrewConfiguration.install_defaults!(workspace: @workspace)
  end

  test "all accounts lists each Workspace account once with unknown health and renewal" do
    visible = @workspace.accounts.create!(name: "Unscored Visible")
    @other.accounts.create!(name: "Other Workspace Hidden")
    page = queue.page(view: "all_accounts")
    names = page.rows.map { |row| row.account.name }

    assert_includes names, visible.name
    refute_includes names, "Other Workspace Hidden"
    assert_equal names, names.uniq
    row = page.rows.find { |candidate| candidate.account.id == visible.id }
    assert row.health_unknown?
    assert row.renewal_unknown?
    assert_includes row.inclusion_reasons, "health_unknown"
    assert_nil row.accountable_membership
  end

  test "renewal approaching uses the 90-day health window and keeps unknown renewal out" do
    inside = scored_account("Inside Window", renewal_on: @as_of + AccountHealth::RENEWAL_WINDOW_DAYS)
    edge = scored_account("Today Renewal", renewal_on: @as_of)
    outside = scored_account("Outside Window", renewal_on: @as_of + AccountHealth::RENEWAL_WINDOW_DAYS + 1)
    unknown = @workspace.accounts.create!(name: "Unknown Renewal")
    page = queue.page(view: "renewal_approaching")
    names = page.rows.map { |row| row.account.name }

    assert_includes names, inside.name
    assert_includes names, edge.name
    refute_includes names, outside.name
    refute_includes names, unknown.name
    assert_includes page.rows.find { |row| row.account.id == inside.id }.inclusion_reasons, "renewal_approaching"
  end

  test "needs attention includes missing health, comparable material change, and open investigation" do
    missing = @workspace.accounts.create!(name: "Needs Health")
    changed = scored_account("Material Shift", renewal_on: @as_of + 120)
    later = drop_health(changed)
    assert later.material_change?
    assert later.previous_assessment_id.present?
    assert later.risk_investigation.present?

    page = queue.page(view: "needs_attention")
    ids = page.rows.map { |row| row.account.id }

    assert_includes ids, missing.id
    assert_includes ids, changed.id
    row = page.rows.find { |candidate| candidate.account.id == changed.id }
    assert_includes row.inclusion_reasons, "material_change"
    assert_includes row.inclusion_reasons, "open_investigation"
    assert_equal "risk-reviews", row.action_anchor
    refute_includes row.inclusion_reasons, "health_unknown"
  end

  test "intervention views keep one row per account, overdue first, and do not treat intervention owner as account owner" do
    awaiting = scored_account("Awaiting Approval", renewal_on: @as_of + 200)
    overdue = scored_account("Overdue Follow-up", renewal_on: @as_of + 200)
    completed = scored_account("Needs Outcome Review", renewal_on: @as_of + 200)
    duplicate = propose_on(awaiting, at: Time.current, target_offset: 14)
    propose_on(awaiting, at: Time.current, target_offset: 21)
    overdue_record = propose_on(overdue, at: 10.days.ago, target_offset: 3)
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: @owner, intervention: overdue_record
    )
    completed_record = propose_on(completed, at: 8.days.ago, target_offset: 2)
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: @owner, intervention: completed_record
    )
    CustomerSuccessInterventionWorkflow.complete!(
      workspace: @workspace, membership: @owner, intervention: completed_record
    )

    approval_page = queue.page(view: "interventions_awaiting_approval")
    assert_equal [ awaiting.id ], approval_page.rows.map { |row| row.account.id }.uniq
    assert_equal 1, approval_page.rows.count { |row| row.account.id == awaiting.id }
    assert_equal duplicate.accountable_membership, approval_page.rows.first.accountable_membership
    assert_equal "customer-success-interventions", approval_page.rows.first.action_anchor

    overdue_page = queue.page(view: "interventions_overdue")
    assert_equal [ overdue.id ], overdue_page.rows.map { |row| row.account.id }

    outcome_page = queue.page(view: "completed_awaiting_outcome_review")
    assert_equal [ completed.id ], outcome_page.rows.map { |row| row.account.id }

    attention = queue.page(view: "needs_attention")
    attention_ids = attention.rows.map { |row| row.account.id }
    assert_operator attention_ids.index(overdue.id), :<, attention_ids.index(awaiting.id)
    overdue_row = attention.rows.find { |row| row.account.id == overdue.id }
    assert_includes overdue_row.inclusion_reasons, "intervention_overdue"
    refute_equal overdue_row.accountable_membership.user_id, overdue_row.account.id
  end

  test "counts share view semantics and stay constant as pages are read" do
    3.times { |index| @workspace.accounts.create!(name: "Count #{index}") }
    scored_account("Renewal Count", renewal_on: @as_of + 10)
    @other.accounts.create!(name: "Foreign Count")
    first = queue.counts
    queue.page(view: "all_accounts")
    queue.page(view: "needs_attention", page: 1)
    assert_equal first, queue.counts
    assert_equal @workspace.accounts.count, first.fetch("all_accounts")
    assert_operator first.fetch("needs_attention"), :>=, 3
    assert_operator first.fetch("renewal_approaching"), :>=, 1
    refute_equal first.fetch("all_accounts"), Account.count
  end

  test "pagination is stable and does not grow queries with the displayed account count" do
    51.times { |index| @workspace.accounts.create!(name: format("Paged %02d", index)) }
    first = sql_count { queue.page(view: "all_accounts", page: 1) }
    second = sql_count { queue.page(view: "all_accounts", page: 2) }
    page_one = queue.page(view: "all_accounts", page: 1)
    page_two = queue.page(view: "all_accounts", page: 2)

    assert_equal AccountWorkQueue::PAGE_SIZE, page_one.rows.length
    assert page_one.has_next_page
    assert_operator page_two.rows.length, :>, 0
    refute_equal page_one.rows.first.account.id, page_two.rows.first.account.id
    assert_equal first, second
    assert_operator first, :<=, 8
  end

  test "unknown view is rejected and existing account listing remains name-ordered" do
    assert_raises(ArgumentError) { queue.page(view: "custom") }
    names = @workspace.accounts.order(:name, :id).pluck(:name)
    assert_equal names, @workspace.accounts.order(:name, :id).pluck(:name)
  end

  private
    def queue
      AccountWorkQueue.new(workspace: @workspace, as_of: @as_of)
    end

    def scored_account(name, renewal_on:)
      account = @workspace.accounts.create!(name:)
      AccountDataImport.import_api!(workspace: @workspace, membership: @owner, rows: [ {
        source_id: "queue-#{name.parameterize}", observed_at: Time.current.iso8601,
        account_name: name, renewal_on: renewal_on.iso8601, active_users: 90, licensed_seats: 100
      } ])
      account.reload
    end

    def drop_health(account)
      AccountDataImport.import_api!(workspace: @workspace, membership: @owner, rows: [ {
        source_id: "queue-#{account.name.parameterize}-drop", observed_at: Time.current.iso8601,
        account_name: account.name, renewal_on: @as_of.iso8601, active_users: 1, licensed_seats: 100
      } ])
      account.reload.current_health_assessment
    end

    def propose_on(account, at:, target_offset:)
      assessment = account.current_health_assessment
      plan, = create_reviewed_intervention_plan(workspace: @workspace, account:, membership: @owner, assessment:)
      travel_to at do
        CustomerSuccessInterventionWorkflow.propose!(
          workspace: @workspace, membership: @owner, account:, assessment:, artifact: plan,
          accountable_membership: @owner,
          expected_observable_change: "Increase deterministic Account health evidence.",
          target_on: at.to_date + target_offset, reason: "Queue fixture follow-up.", at:
        )
      end
    end

    def sql_count
      count = 0
      callback = lambda do |_name, _started, _finished, _id, payload|
        next if payload[:cached]
        next if payload[:name] == "SCHEMA"
        sql = payload[:sql].to_s
        next if sql.start_with?("BEGIN", "COMMIT", "SAVEPOINT", "RELEASE", "ROLLBACK")
        count += 1
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      count
    end
end
