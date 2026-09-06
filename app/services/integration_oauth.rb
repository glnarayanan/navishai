require "net/http"

class IntegrationOauth
  class Unavailable < StandardError; end

  ENDPOINTS = {
    "intercom" => { authorize: "https://app.intercom.com/oauth", token: "https://api.intercom.io/auth/eagle/token" },
    "notion" => { authorize: "https://api.notion.com/v1/oauth/authorize", token: "https://api.notion.com/v1/oauth/token" }
  }.freeze
  MAX_RESPONSE_BYTES = 128.kilobytes

  def initialize(provider)
    @provider = provider
    @endpoints = ENDPOINTS.fetch(provider) { raise Unavailable }
  end

  def configured?
    configuration
    true
  rescue Unavailable
    false
  end

  def authorization_url(state:)
    settings = configuration
    uri = URI(@endpoints.fetch(:authorize))
    values = { client_id: settings.fetch(:client_id), redirect_uri: settings.fetch(:redirect_uri),
      response_type: "code", state: }
    values[:owner] = "user" if @provider == "notion"
    uri.query = URI.encode_www_form(values)
    uri.to_s
  end

  def exchange(code:)
    raise Unavailable unless code.is_a?(String) && code.bytesize.between?(1, 4096)

    settings = configuration
    uri = URI(@endpoints.fetch(:token))
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    payload = { code:, grant_type: "authorization_code", redirect_uri: settings.fetch(:redirect_uri) }
    if @provider == "notion"
      request.basic_auth(settings.fetch(:client_id), settings.fetch(:client_secret))
    else
      payload.merge!(client_id: settings.fetch(:client_id), client_secret: settings.fetch(:client_secret))
    end
    request.body = JSON.generate(payload)
    result = perform(uri, request)
    token = bounded_string(result["access_token"], 16_384)
    if @provider == "notion"
      remote_user_id = bounded_string(result.dig("owner", "user", "id"), 255)
      remote_workspace_id = bounded_string(result["workspace_id"], 255)
    else
      identity = intercom_identity(token:)
      remote_user_id = bounded_string(identity["id"], 255)
      remote_workspace_id = bounded_string(identity.dig("app", "id_code"), 255)
    end
    attributes = { access_token: token, remote_user_id:, remote_workspace_id:, refresh_token: nil, expires_at: nil }
    attributes[:refresh_token] = bounded_string(result["refresh_token"], 16_384) if result["refresh_token"].present?
    if result.key?("expires_in")
      lifetime = result["expires_in"]
      raise Unavailable unless lifetime.is_a?(Integer) && lifetime.between?(1, 366.days.to_i)

      attributes[:expires_at] = lifetime.seconds.from_now
    end
    attributes
  rescue KeyError, TypeError, ArgumentError
    raise Unavailable
  end

  def personal_content(token:)
    bounded_string(token, 16_384)
    if @provider == "notion"
      uri = URI("https://api.notion.com/v1/search")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Notion-Version"] = NotionKnowledgeClient::API_VERSION
      request.body = JSON.generate(page_size: 20, filter: { value: "page", property: "object" })
    else
      uri = URI("https://api.intercom.io/conversations?per_page=20")
      request = Net::HTTP::Get.new(uri)
      request["Intercom-Version"] = IntercomClient::API_VERSION
    end
    request["Authorization"] = "Bearer #{token}"
    result = perform(uri, request)
    rows = result.fetch(@provider == "notion" ? "results" : "conversations")
    raise Unavailable unless rows.is_a?(Array) && rows.size <= 20

    rows.map do |row|
      id = bounded_string(row.fetch("id"), 255)
      title = if @provider == "notion"
        property = row.fetch("properties").values.find { |value| value["type"] == "title" }
        Array(property&.fetch("title", nil)).map { |part| part.fetch("plain_text") }.join.presence || "Untitled page"
      else
        row["title"].presence || "Conversation #{id}"
      end
      { id:, title: bounded_string(title, 4096) }
    end
  rescue KeyError, TypeError, NoMethodError
    raise Unavailable
  end

  def intercom_identity(token:)
    raise Unavailable unless @provider == "intercom"

    bounded_string(token, 16_384)
    uri = URI("https://api.intercom.io/me")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Intercom-Version"] = IntercomClient::API_VERSION
    result = perform(uri, request)
    bounded_string(result["id"], 255)
    bounded_string(result.dig("app", "id_code"), 255)
    result
  end

  private
    def configuration
      prefix = "NAVISHAI_#{@provider.upcase}_OAUTH_"
      values = %i[client_id client_secret redirect_uri].to_h do |key|
        [ key, ENV["#{prefix}#{key.to_s.upcase}"].presence || raise(Unavailable) ]
      end
      uri = URI(values.fetch(:redirect_uri))
      raise Unavailable unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil?

      values
    rescue URI::InvalidURIError
      raise Unavailable
    end

    def bounded_string(value, maximum)
      raise Unavailable unless value.is_a?(String) && value.bytesize.between?(1, maximum) && !value.match?(/[\x00-\x1f\x7f]/)

      value
    end

    def perform(uri, request)
      request["Accept"] = "application/json"
      body = +""
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10, write_timeout: 10) do |http|
        http.request(request) do |response|
          raise Unavailable unless response.is_a?(Net::HTTPSuccess)

          response.read_body do |chunk|
            raise Unavailable if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

            body << chunk
          end
        end
      end
      result = JSON.parse(body)
      raise Unavailable unless result.is_a?(Hash)

      result
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
      raise Unavailable
    end
end
