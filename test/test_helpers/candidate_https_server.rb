# A minimal HTTPS fixture for bootstrap download tests. It serves one candidate
# body with optional byte-range support, an optional abrupt cut on the first
# full transfer, and an optional redirect, using only the Ruby standard library.
require "openssl"
require "socket"

class CandidateHttpsServer
  attr_reader :requests, :ca_path

  def initialize(directory, body:, ranges: true, cut_first_full_after: nil, redirect: nil)
    @body = body
    @ranges = ranges
    @cut_first_full_after = cut_first_full_after
    @redirect = redirect
    @requests = []
    @requests_mutex = Mutex.new
    certificate, key = self_signed_certificate
    @ca_path = File.join(directory, "candidate-ca.pem")
    File.write(@ca_path, certificate.to_pem)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = certificate
    context.key = key
    @tcp = TCPServer.new("127.0.0.1", 0)
    @ssl = OpenSSL::SSL::SSLServer.new(@tcp, context)
    @thread = Thread.new do
      loop do
        socket = begin
          @ssl.accept
        rescue StandardError
          break
        end
        serve(socket)
      end
    end
  end

  def url(path = "/candidate.tar")
    "https://127.0.0.1:#{@tcp.addr[1]}#{path}"
  end

  # Environment that lets the real curl trust this server and bypass any proxy.
  def curl_environment
    { "CURL_CA_BUNDLE" => @ca_path, "NO_PROXY" => "127.0.0.1", "no_proxy" => "127.0.0.1" }
  end

  def stop
    @thread.kill
    @ssl.close
  rescue StandardError
    nil
  end

  private

    def self_signed_certificate
      key = OpenSSL::PKey::RSA.new(2048)
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = 1
      certificate.subject = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
      certificate.issuer = certificate.subject
      certificate.public_key = key.public_key
      certificate.not_before = Time.now - 60
      certificate.not_after = Time.now + 3600
      factory = OpenSSL::X509::ExtensionFactory.new(certificate, certificate)
      certificate.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
      certificate.add_extension(factory.create_extension("subjectAltName", "IP:127.0.0.1"))
      certificate.add_extension(factory.create_extension("keyUsage", "digitalSignature,keyEncipherment,keyCertSign", true))
      certificate.sign(key, OpenSSL::Digest.new("SHA256"))
      [ certificate, key ]
    end

    def serve(socket)
      request_line = socket.gets or return
      _method, path, = request_line.split
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.strip.downcase] = value.to_s.strip
      end
      @requests_mutex.synchronize { @requests << { path:, range: headers["range"] } }
      if @redirect && path == "/redirect"
        socket.write "HTTP/1.1 302 Found\r\nLocation: #{@redirect}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      elsif path != "/candidate.tar"
        socket.write "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      elsif @ranges && headers["range"] =~ /\Abytes=(\d+)-\z/
        serve_range(socket, Regexp.last_match(1).to_i)
      else
        serve_full(socket, headers["range"])
      end
    rescue StandardError
      nil
    ensure
      begin
        socket.close
      rescue StandardError
        nil
      end
    end

    def serve_range(socket, start)
      if start >= @body.bytesize
        socket.write "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */#{@body.bytesize}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        return
      end
      rest = @body.byteslice(start..)
      socket.write "HTTP/1.1 206 Partial Content\r\nContent-Type: application/x-tar\r\nContent-Range: bytes #{start}-#{@body.bytesize - 1}/#{@body.bytesize}\r\nContent-Length: #{rest.bytesize}\r\nConnection: close\r\n\r\n"
      socket.write rest
    end

    def serve_full(socket, range)
      socket.write "HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\nAccept-Ranges: #{@ranges ? 'bytes' : 'none'}\r\nContent-Length: #{@body.bytesize}\r\nConnection: close\r\n\r\n"
      if @cut_first_full_after && range.nil? && !@cut_done
        @cut_done = true
        socket.write @body.byteslice(0, @cut_first_full_after)
        socket.flush
        socket.io.close
        return
      end
      socket.write @body
    end
end
