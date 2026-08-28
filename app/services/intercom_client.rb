require "net/http"

class IntercomClient
  API_ROOT = URI("https://api.intercom.io")
  API_VERSION = "2.16"
  MAX_RESPONSE_BYTES = 10.megabytes
  Response = Data.define(:code, :body)

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class Unavailable < Error; end
  class Rejected < Error; end

  def initialize(connection:, transport: Net::HTTP, attachment_fetcher: IntercomAttachmentFetcher.new)
    @connection = connection
    @transport = transport
    @attachment_fetcher = attachment_fetcher
  end

  def conversation(id)
    request(:get, "/conversations/#{path_segment(id)}")
  end

  def conversations(starting_after: nil)
    query = { per_page: 150 }
    query[:starting_after] = starting_after if starting_after.present?
    request(:get, "/conversations?#{URI.encode_www_form(query)}")
  end

  def admins
    request(:get, "/admins")
  end

  def teams
    request(:get, "/teams")
  end

  def attachment(url)
    @attachment_fetcher.fetch(url)
  rescue IntercomAttachmentFetcher::Error => error
    raise Unavailable, error.message
  end

  def add_note(conversation_id:, admin_id:, body:)
    request(:post, "/conversations/#{path_segment(conversation_id)}/reply", body: {
      message_type: "note", type: "admin", admin_id: admin_id.to_s, body: body.to_s
    })
  end

  def reply(conversation_id:, admin_id:, body:)
    request(:post, "/conversations/#{path_segment(conversation_id)}/reply", body: {
      message_type: "comment", type: "admin", admin_id: admin_id.to_s, body: body.to_s
    })
  end

  def assign(conversation_id:, admin_id:, assignee_id:)
    request(:post, "/conversations/#{path_segment(conversation_id)}/parts", body: {
      message_type: "assignment", type: "admin", admin_id: admin_id.to_s,
      assignee_id: assignee_id.to_s
    })
  end

  def tag(conversation_id:, tag_id:, admin_id:)
    request(
      :post, "/conversations/#{path_segment(conversation_id)}/tags",
      body: { id: tag_id.to_s, admin_id: admin_id.to_s }
    )
  end

  def untag(conversation_id:, tag_id:, admin_id:)
    request(
      :delete, "/conversations/#{path_segment(conversation_id)}/tags/#{path_segment(tag_id)}",
      body: { admin_id: admin_id.to_s }
    )
  end

  def create_tag(name:)
    request(:post, "/tags", body: { name: name.to_s })
  end

  private
    def request(method, path, body: nil)
      raise ConfigurationError, "Intercom access token is not configured" if @connection.access_token.blank?

      uri = API_ROOT + path
      request_class = Net::HTTP.const_get(method.to_s.capitalize)
      http_request = request_class.new(uri)
      http_request["Authorization"] = "Bearer #{@connection.access_token}"
      http_request["Intercom-Version"] = API_VERSION
      http_request["Accept"] = "application/json"
      if body
        http_request["Content-Type"] = "application/json"
        http_request.body = JSON.generate(body)
      end

      response = perform(uri, http_request)
      payload = response.body
      raise Rejected, "Intercom rejected the request (#{response.code})" if response.code.to_i.between?(400, 499)
      raise Unavailable, "Intercom is unavailable (#{response.code})" unless response.code.to_i.between?(200, 299)

      payload.present? ? JSON.parse(payload) : {}
    rescue JSON::ParserError
      raise Unavailable, "Intercom returned invalid JSON"
    rescue IOError, EOFError, SocketError, SystemCallError, Timeout::Error => error
      raise Unavailable, "Intercom request failed: #{error.class}"
    end

    def perform(uri, request)
      @transport.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5, write_timeout: 5) do |http|
        http.request(request) do |response|
          body = +""
          response.read_body do |chunk|
            body << chunk
            raise Unavailable, "Intercom response exceeded the size limit" if body.bytesize > MAX_RESPONSE_BYTES
          end
          return Response.new(code: response.code, body: body)
        end
      end
    end

    def path_segment(value)
      URI.encode_www_form_component(value.to_s)
    end
end
