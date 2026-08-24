require "test_helper"

class Webhooks::SharedEmailControllerTest < ActionDispatch::IntegrationTest
  setup do
    @inbox = workspaces(:acme_support).shared_email_inboxes.create!(
      name: "Support",
      email_address: "support@example.com",
      credential_key: "support"
    )
    @secret = "s" * 32
    @original_secret = ENV["NAVISHAI_SHARED_EMAIL_SUPPORT_WEBHOOK_SECRET"]
    ENV["NAVISHAI_SHARED_EMAIL_SUPPORT_WEBHOOK_SECRET"] = @secret
    @raw_email = <<~EMAIL.gsub("\n", "\r\n")
      From: Alice <alice@example.net>
      To: support@example.com
      Date: Mon, 24 Aug 2026 11:00:00 +0000
      Subject: Signed intake
      Message-ID: <signed@example.net>
      Content-Type: text/plain; charset=UTF-8

      Please help.
    EMAIL
  end

  teardown do
    ENV["NAVISHAI_SHARED_EMAIL_SUPPORT_WEBHOOK_SECRET"] = @original_secret
  end

  test "accepts a current valid signature without a browser session" do
    timestamp = Time.current.to_i

    post webhooks_shared_email_path(@inbox.webhook_key),
      params: @raw_email,
      headers: signed_headers(timestamp)

    assert_response :accepted
    assert_equal "processed", response.parsed_body.fetch("status")
    assert_equal 1, @inbox.inbound_email_deliveries.count
  end

  test "rejects invalid and stale signatures without persisting input" do
    assert_no_difference "InboundEmailDelivery.count" do
      post webhooks_shared_email_path(@inbox.webhook_key),
        params: @raw_email,
        headers: signed_headers(Time.current.to_i).merge("X-NavishAI-Signature" => "bad")
      assert_response :unauthorized

      post webhooks_shared_email_path(@inbox.webhook_key),
        params: @raw_email,
        headers: signed_headers(10.minutes.ago.to_i)
      assert_response :unauthorized
    end
  end

  test "rejects a missing configured secret and an oversized source" do
    ENV.delete("NAVISHAI_SHARED_EMAIL_SUPPORT_WEBHOOK_SECRET")

    assert_no_difference "InboundEmailDelivery.count" do
      post webhooks_shared_email_path(@inbox.webhook_key),
        params: @raw_email,
        headers: signed_headers(Time.current.to_i)
      assert_response :unauthorized

      post webhooks_shared_email_path(@inbox.webhook_key),
        params: "x" * (InboundEmailDelivery::MAX_BYTES + 1),
        headers: signed_headers(Time.current.to_i)
      assert_response :content_too_large
    end
  end

  test "inactive and unknown inbox keys stay hidden" do
    @inbox.update!(active: false)

    post webhooks_shared_email_path(@inbox.webhook_key), params: @raw_email, headers: signed_headers(Time.current.to_i)
    assert_response :not_found

    post webhooks_shared_email_path("unknown"), params: @raw_email, headers: signed_headers(Time.current.to_i)
    assert_response :not_found
  end

  private
    def signed_headers(timestamp)
      signature = OpenSSL::HMAC.hexdigest("SHA256", @secret, "#{timestamp}.#{@raw_email}")
      {
        "CONTENT_TYPE" => "message/rfc822",
        "X-NavishAI-Timestamp" => timestamp.to_s,
        "X-NavishAI-Signature" => signature
      }
    end
end
