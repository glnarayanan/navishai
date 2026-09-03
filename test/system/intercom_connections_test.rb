require "application_system_test_case"

class IntercomConnectionsTest < ApplicationSystemTestCase
  test "owner configures an Intercom connection on desktop and mobile" do
    sign_in(users(:owner))
    visit workspace_shared_email_inboxes_path(workspaces(:acme_support))
    click_on "Intercom", match: :first

    assert_selector "h1", text: "Intercom sync"
    reveal_setup "Add a connection"
    fill_in "Connection name", with: "Support Intercom"
    fill_in "Intercom app ID", with: "app_123"
    fill_in "Credential key", with: "support"
    click_on "Add connection"

    assert_text "Intercom connection added."
    assert_text "app_123"
    assert_text "/webhooks/intercom/"
    assert_text "Historical backfill"
    assert_button "Start new dry run"
    click_on "Pause"
    assert_text "Intercom connection updated."
    assert_text "Paused"

    page.current_window.resize_to(320, 844)
    reveal_setup "Add a connection"
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    page.all("input, button, a.button").first(5).each do |control|
      assert_operator control.rect.height, :>=, 48
    end
  end

  test "owner reviews responsive backfill states and exact final report" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    connection = workspace.intercom_connections.create!(
      name: "History review", remote_workspace_id: "history-review", credential_key: "history_review"
    )
    digest = Digest::SHA256.hexdigest("history-review")
    manifest = connection.intercom_backfill_manifests.create!(
      workspace:, created_by_membership: owner, created_by_user: owner.user,
      source_digest: digest, discovery_records: [ { "id" => "history-1", "source_digest" => digest } ],
      counts: {
        "conversations" => 1, "parts" => 3, "notes" => 1, "attachments" => 1,
        "deterministic_matches" => 0, "ambiguous" => 0, "unsupported_fields" => 0,
        "expected_exceptions" => 1
      },
      available_from: 2.days.ago, available_to: 1.day.ago,
      discovered_at: Time.current, expires_at: 30.minutes.from_now
    )
    manifest.intercom_backfill_exceptions.create!(
      workspace:, remote_record_type: "identity", remote_record_id: "contact-keyless",
      source_digest: digest, exception_kind: "unsupported_field", recovery_action: "restart_preview",
      detail: "Contact has no deterministic email key. Update the source and start a new dry run."
    )
    sign_in(users(:owner))
    visit workspace_intercom_connections_path(workspace)

    within "#historical-backfill-#{connection.id}" do
      assert_text "Review"
      assert_button "Confirm exact manifest"
      assert_text "Frozen digest"
      assert_text "Expected exceptions"
      assert_text "Expected identity exception"
      assert_text "Contact has no deterministic email key"
      assert_text "Start a new dry run below"
    end

    manifest.update!(expires_at: 1.minute.ago)
    refresh
    within "#historical-backfill-#{connection.id}" do
      assert_text "Stale"
      assert_text "This dry run is stale or already used"
    end
    manifest.update!(expires_at: 30.minutes.from_now)
    manifest.update!(status: :consumed, consumed_at: Time.current)
    counts = {
      "discovered" => 1, "imported" => 1, "matched" => 0, "skipped" => 0,
      "ambiguous" => 0, "unsupported" => 0, "failed" => 0, "pending" => 0,
      "attachments" => 1, "notes" => 1
    }
    run = connection.intercom_backfill_runs.create!(
      workspace:, intercom_backfill_manifest: manifest,
      confirmed_by_membership: owner, confirmed_by_user: owner.user,
      status: :pending, source_digest: digest, cursor_position: 0,
      counts: counts.merge("imported" => 0, "pending" => 1), confirmed_at: Time.current
    )
    refresh
    within "#historical-backfill-#{connection.id}" do
      assert_text "Pending"
      assert_text "Bounded batches are in progress"
    end

    run.update!(status: :failed, failure_code: "remote_unavailable", completed_at: Time.current)
    refresh
    within "#historical-backfill-#{connection.id}" do
      assert_text "Failed"
      assert_text "Backfill stopped after a definite boundary"
      assert_button "Resume from definite record"
    end

    exception = manifest.intercom_backfill_exceptions.create!(
      workspace:, intercom_backfill_run: run, remote_record_type: "conversation",
      remote_record_id: "history-1", source_digest: digest, exception_kind: "source_changed",
      recovery_action: "restart_preview", detail: "Intercom changed after confirmation."
    )
    run.update!(status: :blocked, failure_code: "source_changed")
    refresh
    within "#historical-backfill-#{connection.id}" do
      assert_text "Blocked"
      assert_text "Review is required"
      assert_text "Start a new dry run below"
    end

    exception.update!(status: :resolved, resolved_at: Time.current)
    run.update!(
      status: :completed, cursor_position: 1, counts:,
      last_definite_remote_id: "history-1", last_definite_source_digest: digest,
      failure_code: nil, completed_at: Time.current
    )
    run.create_intercom_backfill_report!(
      workspace:, status: :complete, counts:,
      report_digest: Digest::SHA256.hexdigest(JSON.generate(counts)), generated_at: Time.current
    )
    refresh

    within "#historical-backfill-#{connection.id}" do
      assert_text "Complete"
      assert_text "Final preservation report"
      assert_text "Imported\n1"
    end
    page.current_window.resize_to(320, 844)
    refresh
    panel = find("#historical-backfill-#{connection.id}")
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    panel.all("button").each { |button| assert_operator button.rect.height, :>=, 48 }
    panel.find_button("Start new dry run").send_keys(:tab)
    assert page.evaluate_script("document.activeElement !== document.body")
  end
end
