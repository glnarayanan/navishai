require "base64"
require "net/http"
require "openssl"

class OidcProvider
  MAX_RESPONSE_BYTES = 1.megabyte
  CLOCK_SKEW = 60.seconds
  Response = Data.define(:success?, :body)

  class Error < StandardError; end

  def self.configured?
    configuration.values.all?(&:present?)
  end

  def self.configuration
    credentials = Rails.application.credentials
    {
      issuer: ENV["NAVISHAI_OIDC_ISSUER"] || credentials.dig(:oidc, :issuer),
      client_id: ENV["NAVISHAI_OIDC_CLIENT_ID"] || credentials.dig(:oidc, :client_id),
      client_secret: ENV["NAVISHAI_OIDC_CLIENT_SECRET"] || credentials.dig(:oidc, :client_secret)
    }.transform_values { |value| value.to_s.strip.presence }
  end

  def initialize(transport: nil)
    @config = self.class.configuration
    raise Error, "OIDC is not configured" unless @config.values.all?(&:present?)

    @issuer = endpoint(@config.fetch(:issuer))
    raise Error, "OIDC issuer is invalid" if @issuer.query || @issuer.to_s.bytesize > 2_048

    @transport = transport
  end

  def authorization_url(redirect_uri:, state:, nonce:, code_challenge:)
    document = discovery
    query = URI.encode_www_form(
      response_type: "code", client_id: @config.fetch(:client_id), redirect_uri:,
      scope: "openid email", state:, nonce:, code_challenge:, code_challenge_method: "S256"
    )
    uri = endpoint(document.fetch("authorization_endpoint"))
    uri.query = [ uri.query, query ].compact_blank.join("&")
    uri.to_s
  end

  def authenticate!(code:, code_verifier:, redirect_uri:, nonce:)
    raise Error, "authorization code is missing" if code.to_s.blank?

    document = discovery
    token_uri = endpoint(document.fetch("token_endpoint"))
    request = Net::HTTP::Post.new(token_uri.request_uri)
    request.set_form_data(
      grant_type: "authorization_code", code:, redirect_uri:,
      client_id: @config.fetch(:client_id), code_verifier:
    )
    methods = Array(document["token_endpoint_auth_methods_supported"])
    if methods.empty? || methods.include?("client_secret_basic")
      request.basic_auth(@config.fetch(:client_id), @config.fetch(:client_secret))
    elsif methods.include?("client_secret_post")
      request.set_form_data(URI.decode_www_form(request.body).to_h.merge(
        "client_secret" => @config.fetch(:client_secret)
      ))
    else
      raise Error, "OIDC token authentication method is unsupported"
    end
    token = json_response(token_uri, request)
    claims = verify_id_token!(token.fetch("id_token"), document:, nonce:)
    identity_for!(claims)
  rescue KeyError, JSON::ParserError, ArgumentError, OpenSSL::PKey::PKeyError
    raise Error, "OIDC response is invalid"
  end

  private
    def discovery
      uri = @issuer.dup
      uri.path = "#{uri.path.delete_suffix('/')}/.well-known/openid-configuration"
      document = json_response(uri, Net::HTTP::Get.new(uri.request_uri))
      raise Error, "OIDC issuer does not match" unless document["issuer"] == @issuer.to_s

      %w[authorization_endpoint token_endpoint jwks_uri].each { |key| endpoint(document.fetch(key)) }
      document
    rescue KeyError
      raise Error, "OIDC discovery is invalid"
    end

    def verify_id_token!(token, document:, nonce:)
      encoded_header, encoded_claims, encoded_signature = token.to_s.split(".", 3)
      raise Error, "OIDC ID token is invalid" unless encoded_signature

      header = JSON.parse(base64url_decode(encoded_header))
      claims = JSON.parse(base64url_decode(encoded_claims))
      raise Error, "OIDC ID token is invalid" unless header.is_a?(Hash) && claims.is_a?(Hash)

      algorithm = header.fetch("alg")
      digest = { "RS256" => OpenSSL::Digest::SHA256, "RS384" => OpenSSL::Digest::SHA384,
                 "RS512" => OpenSSL::Digest::SHA512 }.fetch(algorithm) do
        raise Error, "OIDC signing algorithm is unsupported"
      end
      key = signing_key(document.fetch("jwks_uri"), header.fetch("kid"), algorithm)
      signature = base64url_decode(encoded_signature)
      raise Error, "OIDC ID token signature is invalid" unless key.verify(digest.new, signature, "#{encoded_header}.#{encoded_claims}")

      validate_claims!(claims, nonce:)
      claims
    end

    def signing_key(jwks_uri, key_id, algorithm)
      uri = endpoint(jwks_uri)
      document = json_response(uri, Net::HTTP::Get.new(uri.request_uri))
      key = Array(document["keys"]).find do |candidate|
        candidate.is_a?(Hash) && candidate["kid"] == key_id && candidate["kty"] == "RSA" &&
          candidate["use"].in?([ nil, "sig" ]) && candidate["alg"].in?([ nil, algorithm ])
      end
      raise Error, "OIDC signing key is missing" unless key

      rsa = OpenSSL::PKey::RSA.new(OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::Integer(base64url_decode(key.fetch("n")).unpack1("H*").to_i(16)),
        OpenSSL::ASN1::Integer(base64url_decode(key.fetch("e")).unpack1("H*").to_i(16))
      ]).to_der)
      raise Error, "OIDC signing key is too small" if rsa.n.num_bits < 2_048

      rsa
    end

    def validate_claims!(claims, nonce:)
      now = Time.current.to_i
      audience = claims["aud"].is_a?(Array) ? claims["aud"] : [ claims["aud"] ]
      valid = claims["iss"] == @issuer.to_s &&
        audience.all? { |value| value.is_a?(String) } && audience.include?(@config.fetch(:client_id)) &&
        claims["exp"].is_a?(Integer) && claims["exp"] > now - CLOCK_SKEW &&
        claims["iat"].is_a?(Integer) && claims["iat"] <= now + CLOCK_SKEW && secure_equal?(claims["nonce"], nonce) &&
        claims["sub"].is_a?(String) && claims["sub"].present? && claims["sub"].bytesize <= 255 &&
        claims["email_verified"] == true &&
        claims["email"].to_s.match?(URI::MailTo::EMAIL_REGEXP)
      valid &&= claims["azp"] == @config.fetch(:client_id) if audience.size > 1
      valid &&= claims["nbf"].is_a?(Integer) && claims["nbf"] <= now + CLOCK_SKEW if claims.key?("nbf")
      raise Error, "OIDC ID token claims are invalid" unless valid
    end

    def identity_for!(claims)
      OidcIdentity.transaction do
        identity = OidcIdentity.lock.find_by(issuer: claims.fetch("iss"), subject: claims.fetch("sub"))
        user = identity&.user || User.lock.find_by(email_address: claims.fetch("email").downcase)
        raise Error, "OIDC account is not invited" unless user&.sign_in_allowed?

        OidcIdentity.create!(user:, issuer: claims.fetch("iss"), subject: claims.fetch("sub")) unless identity
        user
      end
    rescue ActiveRecord::RecordNotUnique
      raise Error, "OIDC identity changed during sign in"
    end

    def json_response(uri, request)
      response = @transport ? @transport.call(uri, request) : perform(uri, request)
      success = response.respond_to?(:success?) ? response.success? : response.is_a?(Net::HTTPSuccess)
      raise Error, "OIDC provider request failed" unless success
      raise Error, "OIDC provider response is too large" if response.body.to_s.bytesize > MAX_RESPONSE_BYTES

      JSON.parse(response.body.to_s).tap do |document|
        raise Error, "OIDC response is invalid" unless document.is_a?(Hash)
      end
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error, "OIDC provider is unavailable"
    end

    def perform(uri, request)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 3
      http.read_timeout = 5
      http.write_timeout = 5
      http.max_retries = 0
      body = +""
      successful = false
      http.request(request) do |response|
        successful = response.is_a?(Net::HTTPSuccess)
        if response["Content-Length"].to_i > MAX_RESPONSE_BYTES
          raise Error, "OIDC provider response is too large"
        end
        response.read_body do |chunk|
          body << chunk
          raise Error, "OIDC provider response is too large" if body.bytesize > MAX_RESPONSE_BYTES
        end
      end
      Response.new(successful, body)
    end

    def endpoint(value)
      uri = URI.parse(value.to_s)
      unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil?
        raise Error, "OIDC endpoint must be HTTPS"
      end
      uri
    rescue URI::InvalidURIError
      raise Error, "OIDC endpoint is invalid"
    end

    def base64url_decode(value)
      value = value.to_s
      Base64.urlsafe_decode64(value.ljust((value.length + 3) / 4 * 4, "="))
    end

    def secure_equal?(left, right)
      left = left.to_s
      right = right.to_s
      left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
end
