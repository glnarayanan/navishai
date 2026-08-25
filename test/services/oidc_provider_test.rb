require "test_helper"

class OidcProviderTest < ActiveSupport::TestCase
  setup do
    @issuer = "https://identity.example.com"
    @client_id = "navishai-test"
    @client_secret = "test-client-secret"
    @key = OpenSSL::PKey::RSA.generate(2_048)
    @nonce = "test-nonce"
    @original_environment = ENV.to_h.slice(
      "NAVISHAI_OIDC_ISSUER", "NAVISHAI_OIDC_CLIENT_ID", "NAVISHAI_OIDC_CLIENT_SECRET"
    )
    ENV["NAVISHAI_OIDC_ISSUER"] = @issuer
    ENV["NAVISHAI_OIDC_CLIENT_ID"] = @client_id
    ENV["NAVISHAI_OIDC_CLIENT_SECRET"] = @client_secret
  end

  teardown do
    %w[NAVISHAI_OIDC_ISSUER NAVISHAI_OIDC_CLIENT_ID NAVISHAI_OIDC_CLIENT_SECRET].each { |key| ENV.delete(key) }
    @original_environment.each { |key, value| ENV[key] = value }
  end

  test "builds a provider-neutral authorization request with PKCE" do
    provider = OidcProvider.new(transport: transport)

    uri = URI.parse(provider.authorization_url(
      redirect_uri: "https://app.example.com/session/oidc/callback",
      state: "state", nonce: @nonce, code_challenge: "challenge"
    ))
    query = URI.decode_www_form(uri.query).to_h

    assert_equal "identity.example.com", uri.host
    assert_equal "/authorize", uri.path
    assert_equal "code", query.fetch("response_type")
    assert_equal "openid email", query.fetch("scope")
    assert_equal "S256", query.fetch("code_challenge_method")
    assert_equal "challenge", query.fetch("code_challenge")
    assert_equal "state", query.fetch("state")
    assert_equal @nonce, query.fetch("nonce")
  end

  test "verifies a signed ID token and binds an invited user" do
    user = users(:owner)

    assert_difference "OidcIdentity.count", 1 do
      assert_equal user, OidcProvider.new(transport: transport).authenticate!(
        code: "authorization-code", code_verifier: "verifier",
        redirect_uri: "https://app.example.com/session/oidc/callback", nonce: @nonce
      )
    end

    identity = OidcIdentity.order(:id).last
    assert_equal user, identity.user
    assert_equal @issuer, identity.issuer
    assert_equal "provider-subject", identity.subject
  end

  test "keeps an existing subject bound when the provider email changes" do
    identity = OidcIdentity.create!(user: users(:owner), issuer: @issuer, subject: "provider-subject")

    user = OidcProvider.new(transport: transport(email: "outsider@example.com")).authenticate!(
      code: "authorization-code", code_verifier: "verifier",
      redirect_uri: "https://app.example.com/session/oidc/callback", nonce: @nonce
    )

    assert_equal identity.user, user
    assert_equal 1, OidcIdentity.where(issuer: @issuer, subject: "provider-subject").count
  end

  test "rejects invalid token claims without binding an identity" do
    invalid_claims = [
      { "nonce" => "wrong" }, { "iss" => "https://other.example.com" },
      { "aud" => "other-client" }, { "exp" => nil }, { "iat" => nil },
      { "email_verified" => false }, { "sub" => "" },
      { "aud" => [ @client_id, "other-client" ], "azp" => nil },
      { "nbf" => 5.minutes.from_now.to_i }
    ]

    invalid_claims.each do |claims|
      assert_no_difference "OidcIdentity.count" do
        error = assert_raises(OidcProvider::Error) do
          OidcProvider.new(transport: transport(claims:)).authenticate!(
            code: "authorization-code", code_verifier: "verifier",
            redirect_uri: "https://app.example.com/session/oidc/callback", nonce: @nonce
          )
        end
        assert_match(/claims/, error.message)
      end
    end
  end

  test "rejects unverified and break-glass accounts" do
    [ { verified_at: nil, break_glass: false }, { verified_at: Time.current, break_glass: true } ].each do |attributes|
      users(:owner).update!(attributes)

      assert_no_difference "OidcIdentity.count" do
        assert_raises(OidcProvider::Error) do
          OidcProvider.new(transport: transport).authenticate!(
            code: "authorization-code", code_verifier: "verifier",
            redirect_uri: "https://app.example.com/session/oidc/callback", nonce: @nonce
          )
        end
      end
    end
  end

  private
    def transport(email: users(:owner).email_address, claims: {})
      lambda do |uri, request|
        body = case uri.path
        when "/.well-known/openid-configuration"
          {
            issuer: @issuer, authorization_endpoint: "#{@issuer}/authorize",
            token_endpoint: "#{@issuer}/token", jwks_uri: "#{@issuer}/keys",
            token_endpoint_auth_methods_supported: [ "client_secret_basic" ]
          }
        when "/token"
          assert_instance_of Net::HTTP::Post, request
          assert_match(/Basic /, request["Authorization"])
          { id_token: id_token(email:, claims:) }
        when "/keys"
          { keys: [ jwk ] }
        else
          flunk "unexpected OIDC request to #{uri}"
        end
        response(body)
      end
    end

    def id_token(email:, claims: {})
      header = { alg: "RS256", kid: "test-key", typ: "JWT" }
      payload = {
        iss: @issuer, aud: @client_id, exp: 5.minutes.from_now.to_i, iat: Time.current.to_i,
        nonce: @nonce, sub: "provider-subject", email:, email_verified: true
      }.stringify_keys.merge(claims)
      encoded_header = encode(JSON.generate(header))
      encoded_payload = encode(JSON.generate(payload))
      signing_input = "#{encoded_header}.#{encoded_payload}"
      "#{signing_input}.#{encode(@key.sign(OpenSSL::Digest::SHA256.new, signing_input))}"
    end

    def jwk
      { kid: "test-key", kty: "RSA", use: "sig", alg: "RS256",
        n: encode(@key.n.to_s(2)), e: encode(@key.e.to_s(2)) }
    end

    def encode(value)
      Base64.urlsafe_encode64(value, padding: false)
    end

    def response(body)
      Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
        response.instance_variable_set(:@read, true)
        response.instance_variable_set(:@body, JSON.generate(body))
      end
    end
end
