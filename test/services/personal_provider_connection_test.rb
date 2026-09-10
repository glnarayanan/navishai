require "test_helper"

class PersonalProviderConnectionTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @account = PersonalProviderAccount.create!(workspace: @workspace, membership: memberships(:owner_support), state: "connected")
    @runtime = approve_scripted_runtime(workspace: @workspace, membership: memberships(:owner_support))
    @runtime.update!(personal_provider_account: @account)
  end

  test "disconnect revokes approval and makes the runtime unavailable" do
    assert @account.usable?
    PersonalProviderConnection.refresh!(account: @account, result: { "state" => "disconnected" })
    assert_not @account.reload.usable?
    assert_not @runtime.reload.approved?
    assert_equal "missing", @runtime.health_status
  end

  test "failed authentication revokes prior approval" do
    PersonalProviderConnection.refresh!(account: @account, result: { "state" => "failed" })
    assert_not @runtime.reload.approved?
    assert_not @account.usable?
  end

  test "membership must belong to the same workspace" do
    account = PersonalProviderAccount.new(workspace: @workspace, membership: memberships(:outsider_beta))
    assert_not account.valid?
    assert_includes account.errors[:membership], "belongs to another workspace"
  end

  test "personal runtime cannot become a shared routing candidate" do
    CrewConfiguration.install_defaults!(workspace: @workspace)
    profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator").current_version
    assert_raises(RuntimeRouter::NoCompatibleRuntime) do
      RuntimeRouter.resolve!(workspace: @workspace, profile_version: profile)
    end
    assert_equal @runtime, RuntimeRouter.resolve!(workspace: @workspace, profile_version: profile, personal_account: @account).installation
    @account.update!(state: "disconnected")
    assert_raises(RuntimeRouter::NoCompatibleRuntime) do
      RuntimeRouter.resolve!(workspace: @workspace, profile_version: profile, personal_account: @account)
    end
  end
end
