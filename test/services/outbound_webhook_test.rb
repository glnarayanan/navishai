require "test_helper"

class OutboundWebhookTest < ActiveSupport::TestCase
  Resolver = Struct.new(:addresses) do
    def getaddresses(host)
      addresses.fetch(host, [])
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @endpoint = @workspace.outbound_webhook_endpoints.create!(
      name: "Ops", url: "https://hooks.example.com/navishai", credential_key: "ops",
      categories: Notification::CATEGORIES
    )
    support_case = create_support_case(subject: "Private subject")
    event = AuditEvent.record!(
      action: "case.status_changed", source: :system, workspace: @workspace, actor_kind: :system,
      subject: support_case, metadata: { from_status: "draft_ready", to_status: "awaiting_human_review" }
    )
    NotificationFanout.call(event)
    @notification = memberships(:owner_support).notifications.last
  end

  test "fanout freezes one content-free delivery per endpoint and notification" do
    assert_difference "OutboundWebhookDelivery.count", 1 do
      OutboundWebhookFanout.call(@notification)
    end
    assert_no_difference "OutboundWebhookDelivery.count" do
      OutboundWebhookFanout.call(@notification)
    end

    delivery = @endpoint.outbound_webhook_deliveries.sole
    payload = JSON.parse(delivery.payload)
    assert_equal @notification.category, payload.fetch("category")
    assert_equal @workspace.runner_key, payload.fetch("workspace_key")
    assert_equal delivery.event_key, payload.fetch("event_id")
    refute_includes delivery.payload, "Private subject"
    assert_equal Digest::SHA256.hexdigest(delivery.payload), delivery.payload_sha256
  end

  test "transport pins public DNS and signs the exact payload" do
    delivery = create_delivery
    captured = nil
    transport = OutboundWebhookTransport.new(
      resolver: Resolver.new({ "hooks.example.com" => [ "93.184.216.34" ] }),
      requester: ->(uri, address, record, signature) { captured = [ uri, address, record, signature ]; 202 }
    )

    prior_secret = ENV["NAVISHAI_WEBHOOK_OPS_SIGNING_SECRET"]
    ENV["NAVISHAI_WEBHOOK_OPS_SIGNING_SECRET"] = "test-secret"
    transport.deliver(delivery:)

    assert_equal "93.184.216.34", captured.second
    assert_equal delivery, captured.third
    expected = OpenSSL::HMAC.hexdigest("SHA256", "test-secret", delivery.payload)
    assert_equal expected, captured.fourth
  ensure
    ENV["NAVISHAI_WEBHOOK_OPS_SIGNING_SECRET"] = prior_secret
  end

  test "transport rejects mixed public and private DNS before request" do
    transport = OutboundWebhookTransport.new(
      resolver: Resolver.new({ "hooks.example.com" => [ "93.184.216.34", "10.0.0.1" ] }),
      requester: ->(*) { flunk "private target must fail before request" }
    )

    error = assert_raises(OutboundWebhookTransport::Error) do
      transport.deliver(delivery: create_delivery)
    end
    assert_not error.retryable
  end

  test "delivery job records success and retries a stale interrupted claim" do
    delivery = create_delivery
    transport = Object.new
    transport.define_singleton_method(:deliver) { |**| nil }
    job = OutboundWebhookDeliveryJob.new
    job.define_singleton_method(:transport) { transport }

    job.perform(delivery.id)
    assert delivery.reload.delivered?
    assert_equal 1, delivery.attempt_count

    stale = create_delivery(notification: create_notification)
    stale.update!(status: :sending, attempt_count: 1, last_attempted_at: 1.hour.ago)
    job.perform(stale.id)
    assert stale.reload.delivered?
    assert_equal 2, stale.attempt_count
  end

  test "paused endpoint leaves a pending delivery untouched" do
    delivery = create_delivery
    @endpoint.update!(active: false)
    transport = Object.new
    transport.define_singleton_method(:deliver) { |**| flunk "paused endpoint must not send" }
    job = OutboundWebhookDeliveryJob.new
    job.define_singleton_method(:transport) { transport }

    job.perform(delivery.id)

    assert delivery.reload.pending?
    assert_equal 0, delivery.attempt_count
  end

  test "database freezes payload and keeps delivery records in one workspace" do
    delivery = create_delivery
    assert_raises(ActiveRecord::StatementInvalid) do
      OutboundWebhookDelivery.transaction(requires_new: true) { delivery.update_column(:payload, "tampered") }
    end

    foreign = workspaces(:beta_support)
    foreign_endpoint = foreign.outbound_webhook_endpoints.create!(
      name: "Foreign", url: "https://foreign.example.com/hook", credential_key: "foreign",
      categories: [ "review" ]
    )
    assert_raises(ActiveRecord::StatementInvalid) do
      OutboundWebhookDelivery.transaction(requires_new: true) do
        OutboundWebhookDelivery.create!(
          workspace: @workspace, outbound_webhook_endpoint: foreign_endpoint, notification: @notification
        )
      end
    end
  end

  private
    def create_delivery(notification: @notification)
      @endpoint.outbound_webhook_deliveries.find_or_create_by!(notification:) { |delivery| delivery.workspace = @workspace }
    end

    def create_notification
      event = AuditEvent.record!(action: "case.assigned", source: :system, workspace: @workspace,
        actor_kind: :system, metadata: { assignee_id: memberships(:owner_support).id })
      NotificationFanout.call(event)
      memberships(:owner_support).notifications.last
    end
end
