require "test_helper"

class OutboundWebhookEndpointsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
  end

  test "owner configures and pauses an audited endpoint" do
    sign_in_as users(:owner)

    get workspace_outbound_webhook_endpoints_path(@workspace)
    assert_response :success
    assert_select "h1", "Outbound webhooks"

    assert_difference [ "OutboundWebhookEndpoint.count", "AuditEvent.count" ], 1 do
      post workspace_outbound_webhook_endpoints_path(@workspace), params: {
        outbound_webhook_endpoint: {
          name: "Ops", url: "https://hooks.example.com/navishai", credential_key: "ops",
          categories: %w[assignment failure]
        }
      }
    end
    endpoint = @workspace.outbound_webhook_endpoints.sole
    assert_redirected_to workspace_outbound_webhook_endpoints_path(@workspace)
    assert_equal %w[assignment failure], endpoint.categories
    assert_equal "webhook.endpoint_configured", AuditEvent.order(:id).last.action

    patch workspace_outbound_webhook_endpoint_path(@workspace, endpoint), params: {
      outbound_webhook_endpoint: endpoint.attributes.slice("name", "url", "credential_key", "categories").merge(active: false)
    }
    assert_not endpoint.reload.active?
  end

  test "invalid and unauthorized endpoint changes fail closed" do
    sign_in_as users(:owner)
    assert_no_difference [ "OutboundWebhookEndpoint.count", "AuditEvent.count" ] do
      post workspace_outbound_webhook_endpoints_path(@workspace), params: {
        outbound_webhook_endpoint: { name: "Bad", url: "https://127.0.0.1/hook", credential_key: "bad", categories: [ "failure" ] }
      }
    end
    assert_response :unprocessable_content
    assert_select ".inline-error", text: /public HTTPS/

    sign_out
    manager = @workspace.memberships.create!(user: users(:teammate), role: :manager)
    sign_in_as manager.user
    get workspace_outbound_webhook_endpoints_path(@workspace)
    assert_response :forbidden
  end
end
