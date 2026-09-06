require "test_helper"

class PersonalProviderAccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @account = PersonalProviderAccount.create!(workspace: @workspace, membership: memberships(:owner_support))
  end

  test "account status is private and never cached" do
    sign_in_as users(:owner)
    with_gateway do
      get workspace_personal_provider_account_path(@workspace, @account)
    end
    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_select "strong", text: "ABCD-1234"
    assert_equal "pending", @account.reload.state
  end

  test "another member cannot inspect or disconnect an account" do
    user = User.create!(email_address: "personal-member@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user:, role: "member")
    sign_in_as user
    get workspace_personal_provider_account_path(@workspace, @account)
    assert_response :not_found
    delete workspace_personal_provider_account_path(@workspace, @account)
    assert_response :not_found
  end

  test "viewer cannot start personal authentication" do
    user = User.create!(email_address: "personal-viewer@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user:, role: "viewer")
    sign_in_as user
    post workspace_personal_provider_accounts_path(@workspace)
    assert_response :forbidden
  end

  private
    def with_gateway
      fake = Object.new
      fake.define_singleton_method(:account) do |**|
        { "state" => "pending", "challenge" => { "verification_url" => "https://auth.openai.com/codex/device", "user_code" => "ABCD-1234", "login_id" => "pending" } }
      end
      original = PersonalProviderGateway.method(:new)
      PersonalProviderGateway.define_singleton_method(:new) { |*| fake }
      yield
    ensure
      PersonalProviderGateway.define_singleton_method(:new, original)
    end
end
