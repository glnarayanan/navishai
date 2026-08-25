require "ipaddr"
require "net/http"
require "openssl"
require "resolv"
require "time"
require "uri"

class KnowledgeUrlFetcher
  MAX_BYTES = KnowledgeSourceVersion::MAX_CONTENT_BYTES
  MAX_REDIRECTS = 3
  ALLOWED_CONTENT_TYPES = %w[text/plain text/html application/xhtml+xml].freeze
  BLOCKED_NETWORKS = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
    198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    ::/96 ::ffff:0:0/96 64:ff9b::/96 64:ff9b:1::/48 100::/64 2001::/32
    2001:2::/48 2001:10::/28 2001:20::/28 2001:db8::/32 2002::/16 3fff::/20
    fc00::/7 fe80::/10 ff00::/8
  ].map { |network| IPAddr.new(network) }.freeze

  Result = Data.define(:content, :url, :retrieved_at, :source_updated_at)
  Response = Data.define(:status, :location, :content_type, :content_length, :body, :last_modified)

  def self.normalize_url(value)
    uri = URI.parse(value.to_s.strip)
    unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
      raise KnowledgeIngestion::InvalidSource, "Use a public HTTPS URL without credentials."
    end

    uri.fragment = nil
    uri.host = uri.host.downcase.delete_suffix(".")
    uri.path = "/" if uri.path.empty?
    if local_hostname?(uri.host) || blocked_address?(uri.host)
      raise KnowledgeIngestion::InvalidSource, "Use a public HTTPS URL without credentials."
    end
    uri
  rescue URI::InvalidURIError
    raise KnowledgeIngestion::InvalidSource, "Use a valid HTTPS URL."
  end

  def initialize(resolver: Resolv, requester: nil)
    @resolver = resolver
    @requester = requester || method(:request)
  end

  def fetch(url, now: Time.current)
    uri = parse_url(url)
    redirects = 0

    loop do
      address = public_address_for(uri.host)
      response = @requester.call(uri, address)
      if response.status.in?(300..399)
        raise KnowledgeIngestion::InvalidSource, "The source redirected without a location." if response.location.blank?
        raise KnowledgeIngestion::InvalidSource, "The source redirected too many times." if redirects >= MAX_REDIRECTS

        uri = parse_url(URI.join(uri.to_s, response.location).to_s)
        redirects += 1
        next
      end
      raise KnowledgeIngestion::InvalidSource, "The source returned HTTP #{response.status}." unless response.status.in?(200..299)

      content_type = response.content_type.to_s.downcase.split(";", 2).first
      unless ALLOWED_CONTENT_TYPES.include?(content_type)
        raise KnowledgeIngestion::InvalidSource, "The source must return plain text or HTML."
      end
      if response.content_length.to_i > MAX_BYTES || response.body.bytesize > MAX_BYTES
        raise KnowledgeIngestion::InvalidSource, "The fetched source must be 1 MiB or less."
      end

      content = content_type == "text/plain" ? normalize_text(response.body) : html_to_text(response.body)
      raise KnowledgeIngestion::InvalidSource, "The fetched source has no readable text." if content.blank?

      return Result.new(
        content:, url: uri.to_s, retrieved_at: now,
        source_updated_at: parse_http_time(response.last_modified)
      )
    end
  rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
    Rails.logger.warn("Knowledge URL fetch failed: #{error.class}")
    raise KnowledgeIngestion::InvalidSource, "The source could not be fetched securely."
  end

  private
    def parse_url(value)
      self.class.normalize_url(value)
    end

    def public_address_for(host)
      addresses = @resolver.getaddresses(host).map { |address| IPAddr.new(address) }
      if addresses.empty? || addresses.any? { |address| BLOCKED_NETWORKS.any? { |network| network.include?(address) } }
        raise KnowledgeIngestion::InvalidSource, "The source URL must resolve only to public addresses."
      end

      addresses.first.to_s
    rescue IPAddr::InvalidAddressError
      raise KnowledgeIngestion::InvalidSource, "The source URL has an invalid address."
    end

    def request(uri, address)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.ipaddr = address
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10
      http.write_timeout = 5
      request = Net::HTTP::Get.new(uri.request_uri, {
        "Accept" => "text/plain, text/html, application/xhtml+xml",
        "Accept-Encoding" => "identity",
        "User-Agent" => "NavishAI knowledge ingestion"
      })

      http.start do |connection|
        connection.request(request) do |net_response|
          if net_response["content-encoding"].present? && net_response["content-encoding"] != "identity"
            raise KnowledgeIngestion::InvalidSource, "The source returned unsupported content encoding."
          end
          length = net_response["content-length"].to_i
          if length > MAX_BYTES
            raise KnowledgeIngestion::InvalidSource, "The fetched source must be 1 MiB or less."
          end

          body = +"".b
          unless net_response.is_a?(Net::HTTPRedirection)
            net_response.read_body do |chunk|
              body << chunk
              if body.bytesize > MAX_BYTES
                raise KnowledgeIngestion::InvalidSource, "The fetched source must be 1 MiB or less."
              end
            end
          end
          return Response.new(
            status: net_response.code.to_i,
            location: net_response["location"],
            content_type: net_response["content-type"],
            content_length: length,
            body:, last_modified: net_response["last-modified"]
          )
        end
      end
    end

    def html_to_text(html)
      document = Nokogiri::HTML5(html)
      document.css("script, style, noscript, svg").remove
      normalize_text(document.at("body")&.text.to_s)
    end

    def normalize_text(text)
      text.to_s.encode("UTF-8", invalid: :replace, undef: :replace).squish
    end

    def parse_http_time(value)
      Time.httpdate(value) if value.present?
    rescue ArgumentError
      nil
    end

    def self.blocked_address?(host)
      address = IPAddr.new(host)
      BLOCKED_NETWORKS.any? { |network| network.include?(address) }
    rescue IPAddr::InvalidAddressError
      false
    end

    def self.local_hostname?(host)
      return true if host == "localhost" || host.end_with?(".localhost", ".local", ".internal", ".home.arpa")

      IPAddr.new(host)
      false
    rescue IPAddr::InvalidAddressError
      !host.include?(".")
    end
    private_class_method :blocked_address?, :local_hostname?
end
