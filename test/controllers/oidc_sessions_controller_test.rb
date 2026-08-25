require "test_helper"

class OidcSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @issuer = "https://identity.example.com"
    @client_id = "navishai-test"
    @key = OpenSSL::PKey::RSA.generate(2_048)
    @original_environment = ENV.to_h.slice(
      "NAVISHAI_OIDC_ISSUER", "NAVISHAI_OIDC_CLIENT_ID", "NAVISHAI_OIDC_CLIENT_SECRET"
    )
    ENV["NAVISHAI_OIDC_ISSUER"] = @issuer
    ENV["NAVISHAI_OIDC_CLIENT_ID"] = @client_id
    ENV["NAVISHAI_OIDC_CLIENT_SECRET"] = "test-client-secret"
    Rails.application.config.x.oidc_transport = method(:request)
  end

  teardown do
    Rails.application.config.x.oidc_transport = nil
    %w[NAVISHAI_OIDC_ISSUER NAVISHAI_OIDC_CLIENT_ID NAVISHAI_OIDC_CLIENT_SECRET].each { |key| ENV.delete(key) }
    @original_environment.each { |key, value| ENV[key] = value }
  end

  test "shows single sign-on only when it is configured" do
    get new_session_path
    assert_select "form[action='#{oidc_session_path}'] button", text: "Continue with single sign-on"

    ENV.delete("NAVISHAI_OIDC_CLIENT_SECRET")
    get new_session_path
    assert_select "form[action='#{oidc_session_path}']", count: 0
  end

  test "signs in an invited user and consumes the flow once" do
    workspace = workspaces(:acme_support)
    get workspace_path(workspace)
    assert_redirected_to new_session_path

    post oidc_session_path
    assert_response :redirect
    authorization_uri = URI.parse(response.location)
    query = URI.decode_www_form(authorization_uri.query).to_h
    @nonce = query.fetch("nonce")
    state = query.fetch("state")
    assert_equal "S256", query.fetch("code_challenge_method")

    assert_difference [ "OidcIdentity.count", "Session.oidc.count", "AuditEvent.count" ], 1 do
      get oidc_session_callback_path, params: { code: "code", state: state }
    end

    assert_redirected_to workspace_path(workspace)
    assert cookies[:session_id]
    assert_equal users(:owner), OidcIdentity.order(:id).last.user
    event = AuditEvent.order(:id).last
    assert_equal "authentication.succeeded", event.action
    assert_equal({ "method" => "oidc" }, event.metadata)

    assert_no_difference [ "OidcIdentity.count", "Session.oidc.count" ] do
      get oidc_session_callback_path, params: { code: "code", state: state }
    end
    assert_redirected_to new_session_path
  end

  test "rejects a state mismatch before the token request" do
    post oidc_session_path
    @token_requested = false

    assert_difference "AuditEvent.count", 1 do
      get oidc_session_callback_path, params: { code: "code", state: "wrong" }
    end

    assert_not @token_requested
    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
    event = AuditEvent.order(:id).last
    assert_equal "authentication.failed", event.action
    assert_equal({ "method" => "oidc" }, event.metadata)
  end

  test "rejects an expired flow" do
    post oidc_session_path
    state = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("state")
    @token_requested = false

    travel 11.minutes do
      get oidc_session_callback_path, params: { code: "code", state: state }
    end

    assert_not @token_requested
    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  private
    def request(uri, _request)
      body = case uri.path
      when "/.well-known/openid-configuration"
        {
          issuer: @issuer, authorization_endpoint: "#{@issuer}/authorize",
          token_endpoint: "#{@issuer}/token", jwks_uri: "#{@issuer}/keys"
        }
      when "/token"
        @token_requested = true
        { id_token: id_token }
      when "/keys"
        { keys: [ { kid: "test-key", kty: "RSA", use: "sig",
                    n: encode(@key.n.to_s(2)), e: encode(@key.e.to_s(2)) } ] }
      else
        flunk "unexpected OIDC request to #{uri}"
      end
      Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
        response.instance_variable_set(:@read, true)
        response.instance_variable_set(:@body, JSON.generate(body))
      end
    end

    def id_token
      header = encode(JSON.generate(alg: "RS256", kid: "test-key"))
      claims = encode(JSON.generate(
        iss: @issuer, aud: @client_id, exp: 5.minutes.from_now.to_i, iat: Time.current.to_i,
        nonce: @nonce, sub: "provider-subject", email: users(:owner).email_address, email_verified: true
      ))
      input = "#{header}.#{claims}"
      "#{input}.#{encode(@key.sign(OpenSSL::Digest::SHA256.new, input))}"
    end

    def encode(value)
      Base64.urlsafe_encode64(value, padding: false)
    end
end
