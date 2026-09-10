require "net/http"

class NotionKnowledgeClient
  class Error < StandardError; end
  class Missing < Error; end
  API_VERSION = "2025-09-03"
  MAX_REQUESTS = 100

  def initialize(connection:)
    @connection = connection
  end

  def page(id)
    request(:get, "/v1/pages/#{page_id(id)}")
  end

  def document(id)
    @requests = 0
    @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    metadata = page(id)
    return { metadata:, text: "", children: [] } if metadata["archived"] || metadata["in_trash"]

    @children = []
    @lines = []
    @bytes = 0
    begin
      blocks(id, depth: 0)
    rescue Missing
      raise Error, "notion_incomplete_document"
    end
    { metadata:, text: @lines.join("\n"), children: @children.uniq }
  ensure
    @deadline = nil
  end

  private
    def blocks(id, depth:)
      raise Error, "notion_depth_limit" if depth > 10

      each_result("/v1/blocks/#{page_id(id)}/children") do |block|
        type = block.fetch("type")
        value = block.fetch(type)
        raise Error, "notion_malformed" unless value.is_a?(Hash)

        case type
        when "child_page"
          @children << page_id(block.fetch("id"))
          append("[Child page: #{value.fetch('title')}]")
        when "child_database"
          database_pages(block.fetch("id"))
          append("[Database: #{value.fetch('title')}]")
        when "paragraph", "heading_1", "heading_2", "heading_3", "bulleted_list_item", "numbered_list_item", "quote", "callout", "toggle", "to_do", "code"
          append(rich_text(value.fetch("rich_text")))
        when "table_row"
          append(value.fetch("cells").map { |cell| rich_text(cell) }.join(" | "))
        when "divider"
          append("---")
        when "table", "column_list", "column"
        else
          append("[Content omitted: unsupported Notion block #{type}]")
        end
        blocks(block.fetch("id"), depth: depth + 1) if block["has_children"] && !%w[child_page child_database].include?(type)
      end
    rescue KeyError, TypeError, NoMethodError
      raise Error, "notion_malformed"
    end

    def database_pages(id)
      database = request(:get, "/v1/databases/#{page_id(id)}")
      sources = database.fetch("data_sources")
      raise Error, "notion_scan_limit" unless sources.is_a?(Array) && sources.size <= 20

      sources.each do |source|
        each_result("/v1/data_sources/#{page_id(source.fetch('id'))}/query", method: :post) do |page|
          @children << page_id(page.fetch("id")) unless page["archived"] || page["in_trash"]
          raise Error, "notion_scan_limit" if @children.size > 1000
        end
      end
    end

    def each_result(path, method: :get)
      cursor = nil
      cursors = []
      loop do
        params = { page_size: 100 }
        params[:start_cursor] = cursor if cursor
        response = request(method, path, params:)
        results = response.fetch("results")
        raise Error, "notion_malformed" unless results.is_a?(Array) && results.size <= 100

        results.each { |result| yield result }
        break if response["has_more"] == false
        cursor = response["next_cursor"]
        raise Error, "notion_invalid_cursor" unless response["has_more"] == true && cursor.is_a?(String) &&
          cursor.bytesize.in?(1..2048) && !cursors.include?(cursor)

        cursors << cursor
      end
    end

    def rich_text(values)
      raise Error, "notion_malformed" unless values.is_a?(Array)

      values.map { |value| value.fetch("plain_text") }.join
    end

    def append(text)
      raise Error, "notion_malformed" unless text.is_a?(String)

      @bytes += text.bytesize + 1
      raise Error, "notion_content_limit" if @bytes > KnowledgeSourceVersion::MAX_CONTENT_BYTES

      @lines << text
    end

    def page_id(id)
      raise Error, "notion_invalid_page_id" unless id.is_a?(String) && id.match?(NotionKnowledgeConnection::PAGE_ID)

      id
    end

    def request(method, path, params: {})
      raise Error, "notion_scan_limit" if (@requests = (@requests || 0) + 1) > MAX_REQUESTS ||
        (@deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline)
      raise Error, "notion_disabled" unless @connection.reload.ready?

      uri = URI("https://api.notion.com#{path}")
      uri.query = URI.encode_www_form(params) if method == :get && params.any?
      request = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@connection.workspace_connector.service_access_token}"
      request["Notion-Version"] = API_VERSION
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(params) if method == :post
      body = +""
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10, write_timeout: 10) do |http|
        http.request(request) do |response|
          raise Missing, "notion_missing" if response.code == "404"
          raise Error, "notion_unavailable" unless response.is_a?(Net::HTTPSuccess)

          response.read_body do |chunk|
            raise Error, "notion_response_limit" if body.bytesize + chunk.bytesize > 2.megabytes

            body << chunk
          end
        end
      end
      value = JSON.parse(body)
      raise Error, "notion_malformed" unless value.is_a?(Hash)

      value
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, IntegrationOauth::Unavailable
      raise Error, "notion_unavailable"
    end
end
