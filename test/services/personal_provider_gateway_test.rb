require "test_helper"

class PersonalProviderGatewayTest < ActiveSupport::TestCase
  setup do
    @workspace_key = SecureRandom.uuid
    @account_key = SecureRandom.uuid
    @gateway = PersonalProviderGateway.allocate
    @value = { "protocol_version" => "v1", "account" => {
      "workspace_key" => @workspace_key, "membership_id" => 42, "account_key" => @account_key,
      "state" => "pending", "challenge" => { "verification_url" => "https://auth.openai.com/codex/device", "user_code" => "ABCD-1234", "login_id" => "login" }
    } }
  end

  test "accepts a bound pending challenge without storing credentials" do
    assert_equal "pending", parse.fetch("state")
  end

  test "rejects another owner or workspace and arbitrary sign-in URLs" do
    @value["account"]["membership_id"] = 43
    assert_raises(RunnerClient::MalformedResponse) { parse }
    @value["account"]["membership_id"] = 42
    @value["account"]["challenge"]["verification_url"] = "https://example.com/login"
    assert_raises(RunnerClient::MalformedResponse) { parse }
  end

  test "rejects credentials and a connected state without sentinel evidence" do
    @value["account"]["access_token"] = "secret"
    assert_raises(RunnerClient::MalformedResponse) { parse }
    @value["account"].delete("access_token")
    @value["account"]["state"] = "connected"
    assert_raises(RunnerClient::MalformedResponse) { parse }
  end

  private
    def parse
      @gateway.send(:parse_account, JSON.generate(@value), workspace_key: @workspace_key, membership_id: 42, account_key: @account_key)
    end
end
