require "application_system_test_case"

class ViewportOverflowTest < ApplicationSystemTestCase
  test "every authenticated route family fits a 1024 pixel canvas" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    support_case = create_support_case
    add_inbound_message(support_case)
    memory = workspace.memory_records.create!(
      memory_type: :profile, scope_kind: :workspace, topic: "contact-window",
      content: "Customer prefers morning contact.", authority: :source_record, origin_kind: :system,
      source_reference: "test://contact-window", source_digest: Digest::SHA256.hexdigest("morning"),
      observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 0.8, retention_policy: :indefinite
    )
    AccountHealth.recalculate!(workspace:, account: accounts(:acme), trigger_kind: "human_request", membership: owner)

    sign_in(owner.user)
    page.current_window.resize_to(1024, 900)

    routes = [
      [ "landing", root_path ],
      [ "workspaces", workspaces_path ],
      [ "workspace", workspace_path(workspace) ],
      [ "cases", workspace_support_cases_path(workspace) ],
      [ "case", workspace_support_case_path(workspace, support_case) ],
      [ "accounts", workspace_accounts_path(workspace) ],
      [ "account", workspace_account_path(workspace, accounts(:acme)) ],
      [ "knowledge", workspace_knowledge_sources_path(workspace) ],
      [ "memory", workspace_memory_records_path(workspace) ],
      [ "memory detail", workspace_memory_record_path(workspace, memory) ],
      [ "scorecard", workspace_health_scorecard_path(workspace) ],
      [ "crews", workspace_crew_templates_path(workspace) ],
      [ "runtimes", workspace_runtime_installations_path(workspace) ],
      [ "email", workspace_shared_email_inboxes_path(workspace) ],
      [ "intercom", workspace_intercom_connections_path(workspace) ],
      [ "webhooks", workspace_outbound_webhook_endpoints_path(workspace) ],
      [ "data", workspace_data_controls_path(workspace) ],
      [ "notifications", workspace_notifications_path(workspace) ],
      [ "invitations", workspace_workspace_invitations_path(workspace) ],
      [ "crew work", workspace_support_case_crew_tasks_path(workspace, support_case) ]
    ]

    routes.each do |name, path|
      visit path
      assert_no_horizontal_overflow
      next if name == "landing"

      assert_no_selector ".app-sidebar", visible: true
      assert_button "Open navigation"
    end

    page.current_window.resize_to(1440, 1000)
    visit workspace_accounts_path(workspace)
    page.execute_script("window.scrollTo(48, 0)")
    page.current_window.resize_to(1024, 900)
    visit workspace_account_path(workspace, accounts(:acme))
    assert_equal 0, page.evaluate_script("window.scrollX")
    assert_no_horizontal_overflow
  end

  private
    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end
end
