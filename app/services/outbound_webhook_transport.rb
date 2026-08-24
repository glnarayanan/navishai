require "ipaddr"
require "net/http"
require "openssl"
require "resolv"

class OutboundWebhookTransport
  class Error < StandardError
    attr_reader :retryable

    def initialize(message, retryable:)
      @retryable = retryable
      super(message)
    end
  end

  def initialize(resolver: Resolv, requester: nil)
    @resolver = resolver
    @requester = requester || method(:request)
  end

  def deliver(delivery:)
    uri = GuardedWebFetcher.normalize_url(delivery.target_url)
    addresses = @resolver.getaddresses(uri.host).map { |address| IPAddr.new(address) }
    if addresses.empty? || addresses.any? { |address| GuardedWebFetcher::BLOCKED_NETWORKS.any? { |network| network.include?(address) } }
      raise Error.new("endpoint does not resolve only to public addresses", retryable: false)
    end

    signature = OpenSSL::HMAC.hexdigest("SHA256", delivery.signing_secret, delivery.payload)
    status = @requester.call(uri, addresses.first.to_s, delivery, signature)
    return if status.in?(200..299)

    raise Error.new("endpoint returned HTTP #{status}", retryable: status >= 500)
  rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
    Rails.logger.warn("Outbound webhook failed: #{error.class}")
    raise Error.new("endpoint could not be reached securely", retryable: true)
  rescue GuardedWebFetcher::Error, KeyError => error
    raise Error.new(error.message, retryable: false)
  rescue IPAddr::InvalidAddressError
    raise Error.new("endpoint resolved to an invalid address", retryable: false)
  end

  private
    def request(uri, address, delivery, signature)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.ipaddr = address
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10
      http.write_timeout = 5
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "NavishAI outbound webhook"
      request["X-NavishAI-Event"] = delivery.event_key
      request["X-NavishAI-Signature"] = signature
      request.body = delivery.payload
      http.start { |connection| connection.request(request).code.to_i }
    end
end
