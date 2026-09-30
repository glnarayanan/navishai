require "test_helper"

class LabBaselineTest < ActionDispatch::IntegrationTest
  test "old product routes are gone even for an Owner" do
    sign_in_as users(:owner)
    %w[cases accounts crews knowledge memory runtimes scorecard policies reliability email-inboxes].each do |path|
      get "/workspaces/#{workspaces(:acme_support).id}/#{path}"
      assert_response :not_found
    end
    post "/webhooks/runner-events", params: {}
    assert_response :not_found
    %w[SupportCase CrewTask ExecutionRun MemoryRecord Account RuntimeInstallation].each do |name|
      assert_nil name.safe_constantize
    end
  end

  test "the authorized workspace renders a truthful empty lab" do
    sign_in_as users(:owner)
    get workspace_path(workspaces(:acme_support))
    assert_response :success
    assert_select "h2", "A clean starting point"
    assert_select "a", text: "Manage invitations"
    assert_select "button[disabled]", count: 0
  end

  test "organization membership elsewhere grants no workspace access" do
    sign_in_as users(:owner)
    get workspace_path(workspaces(:acme_success))
    assert_response :not_found
  end

  test "database baseline contains only retained tables" do
    expected = %w[ar_internal_metadata audit_events installation_states memberships oidc_identities organizations schema_migrations sessions users workspace_invitations workspaces]
    assert_equal expected.sort, ApplicationRecord.connection.tables.sort
    assert_empty ApplicationRecord.connection.select_values("SELECT extname FROM pg_extension WHERE extname = 'vector'")
  end

  test "foreign keys and role checks reject bypassing model validation" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Membership.transaction(requires_new: true) { Membership.where(id: memberships(:teammate_success).id).update_all(workspace_id: -1) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      Membership.transaction(requires_new: true) { Membership.where(id: memberships(:teammate_success).id).update_all(role: "superuser") }
    end
  end
end
