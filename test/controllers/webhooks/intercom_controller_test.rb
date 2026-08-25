require "test_helper"

class Webhooks::IntercomControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @connection = @workspace.intercom_connections.create!(
      name: "Support Intercom", remote_workspace_id: "app_123", credential_key: "webhook_test"
    )
    @secret = "s" * 32
    @environment_key = "NAVISHAI_INTERCOM_WEBHOOK_TEST_CLIENT_SECRET"
    @previous_secret = ENV[@environment_key]
    ENV[@environment_key] = @secret
    @raw_payload = JSON.generate(
      type: "notification_event", id: "notification_1", app_id: "app_123",
      topic: "contact.user.created",
      data: { item: { type: "contact", id: "contact_1", email: "hook@example.net", name: "Hook" } }
    )
  end

  teardown do
    ENV[@environment_key] = @previous_secret
  end

  test "accepts a bounded signed event and replays it idempotently" do
    signature = "sha1=#{OpenSSL::HMAC.hexdigest('SHA1', @secret, @raw_payload)}"

    assert_difference "IntercomWebhookDelivery.count", 1 do
      post webhooks_intercom_path(@connection.webhook_key), params: @raw_payload,
        headers: { "CONTENT_TYPE" => "application/json", "X-Hub-Signature" => signature }
      assert_response :accepted
      post webhooks_intercom_path(@connection.webhook_key), params: @raw_payload,
        headers: { "CONTENT_TYPE" => "application/json", "X-Hub-Signature" => signature }
      assert_response :accepted
    end
  end

  test "rejects an invalid signature before persistence" do
    assert_no_difference "IntercomWebhookDelivery.count" do
      post webhooks_intercom_path(@connection.webhook_key), params: @raw_payload,
        headers: { "CONTENT_TYPE" => "application/json", "X-Hub-Signature" => "sha1=#{'0' * 40}" }
    end
    assert_response :unauthorized
  end

  test "rejects a declared oversized payload before reading it" do
    assert_no_difference "IntercomWebhookDelivery.count" do
      post webhooks_intercom_path(@connection.webhook_key), params: "{}",
        headers: { "CONTENT_TYPE" => "application/json", "CONTENT_LENGTH" => (IntercomWebhookDelivery::MAX_BYTES + 1).to_s }
    end
    assert_response :content_too_large
  end
end
