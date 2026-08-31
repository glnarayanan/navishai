require "test_helper"

class SecurityBaselineTest < ActionDispatch::IntegrationTest
  test "browser responses include the security policy" do
    get new_session_path

    assert_response :success
    assert_equal "DENY", response.headers["X-Frame-Options"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_equal "same-origin", response.headers["Cross-Origin-Opener-Policy"]
    assert_equal "same-origin", response.headers["Cross-Origin-Resource-Policy"]
    assert_includes response.headers["Permissions-Policy"], "camera=()"
    assert_includes response.headers["Content-Security-Policy"], "default-src 'self'"
    assert_includes response.headers["Content-Security-Policy"], "frame-ancestors 'none'"
    assert_select "script[nonce]", minimum: 1
  end

  test "secret URL values use filtered query parameters instead of path segments" do
    token = "unique-secret-token"

    get verification_path(token: token)

    assert_equal "/verification?token=[FILTERED]", request.filtered_path
    assert_not_includes request.path, token
  end

  test "logging filters every credential field used by security flows" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    parameters = {
      password: "password-value",
      password_confirmation: "password-value",
      bootstrap_token: "bootstrap-value",
      deployment_token: "deployment-value",
      api_key: "provider-key",
      credential_value: "credential-value",
      authorization_code: "authorization-code",
      device_code: "device-code",
      provider_credential: "provider-credential",
      email_address: "owner@example.com",
      public_web_query: "owner@example.com token=secret",
      safe_role: "manager"
    }

    filtered = filter.filter(parameters)

    assert_equal "[FILTERED]", filtered[:password]
    assert_equal "[FILTERED]", filtered[:password_confirmation]
    assert_equal "[FILTERED]", filtered[:bootstrap_token]
    assert_equal "[FILTERED]", filtered[:deployment_token]
    assert_equal "[FILTERED]", filtered[:api_key]
    assert_equal "[FILTERED]", filtered[:credential_value]
    assert_equal "[FILTERED]", filtered[:authorization_code]
    assert_equal "[FILTERED]", filtered[:device_code]
    assert_equal "[FILTERED]", filtered[:provider_credential]
    assert_equal "[FILTERED]", filtered[:email_address]
    assert_equal "[FILTERED]", filtered[:public_web_query]
    assert_equal "manager", filtered[:safe_role]
  end

  test "security rate limits have shared conservative defaults" do
    assert_equal({ to: 10, within: 3.minutes, scope: :authentication }, SecurityRateLimits::AUTHENTICATION)
    assert_equal({ to: 5, within: 10.minutes, scope: :sensitive }, SecurityRateLimits::SENSITIVE)
  end
end
