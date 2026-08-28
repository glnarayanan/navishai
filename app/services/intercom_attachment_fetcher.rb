require "ipaddr"
require "net/http"
require "openssl"
require "resolv"

class IntercomAttachmentFetcher
  class Error < StandardError; end

  MAX_REDIRECTS = 3

  def initialize(resolver: Resolv, requester: nil)
    @resolver = resolver
    @requester = requester || method(:request)
  end

  def fetch(url)
    uri = GuardedWebFetcher.normalize_url(url)
    redirects = 0
    loop do
      address = public_address_for(uri.host)
      response = @requester.call(uri, address)
      if response.fetch(:status).in?(300..399)
        raise Error, "Intercom attachment redirected without a location" if response[:location].blank?
        raise Error, "Intercom attachment redirected too many times" if redirects >= MAX_REDIRECTS

        uri = GuardedWebFetcher.normalize_url(URI.join(uri.to_s, response.fetch(:location)).to_s)
        redirects += 1
        next
      end
      raise Error, "Intercom attachment returned HTTP #{response.fetch(:status)}" unless response.fetch(:status).in?(200..299)

      return response.fetch(:body)
    end
  rescue GuardedWebFetcher::Error => error
    raise Error, error.message
  rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
    Rails.logger.warn("Intercom attachment fetch failed: #{error.class}")
    raise Error, "Intercom attachment could not be fetched securely"
  end

  private
    def public_address_for(host)
      addresses = @resolver.getaddresses(host).map { |address| IPAddr.new(address) }
      if addresses.empty? || addresses.any? do |address|
          GuardedWebFetcher::BLOCKED_NETWORKS.any? { |network| network.include?(address) }
        end
        raise Error, "Intercom attachment URL must resolve only to public addresses"
      end

      addresses.first.to_s
    rescue IPAddr::InvalidAddressError
      raise Error, "Intercom attachment URL has an invalid address"
    end

    def request(uri, address)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.ipaddr = address
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10
      http.write_timeout = 5
      request = Net::HTTP::Get.new(uri.request_uri, {
        "Accept" => "application/octet-stream, text/plain, application/pdf, image/png, image/jpeg, image/gif",
        "Accept-Encoding" => "identity", "User-Agent" => "NavishAI Intercom attachment import"
      })
      http.start do |connection|
        connection.request(request) do |net_response|
          if net_response["content-encoding"].present? && net_response["content-encoding"] != "identity"
            raise Error, "Intercom attachment used unsupported content encoding"
          end
          length = net_response["content-length"].to_i
          raise Error, "Intercom attachment exceeds the 5 MiB limit" if length > StoredAttachment::MAX_BYTES

          body = +"".b
          unless net_response.is_a?(Net::HTTPRedirection)
            net_response.read_body do |chunk|
              body << chunk
              raise Error, "Intercom attachment exceeds the 5 MiB limit" if body.bytesize > StoredAttachment::MAX_BYTES
            end
          end
          return {
            status: net_response.code.to_i, location: net_response["location"], body:
          }
        end
      end
    end
end
