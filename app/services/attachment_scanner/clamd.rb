require "socket"

# Reference malware-scan adapter for a deployment-run ClamAV daemon.
#
# It speaks clamd's INSTREAM protocol over a TCP or Unix socket using only the
# Ruby standard library. Every failure path (unreachable daemon, timeout,
# protocol error, oversized stream, unexpected reply) returns `unavailable`, so
# AttachmentIntake keeps the file quarantined. Only an explicit "OK" reply marks
# a file clean and only an explicit "FOUND" reply marks it infected. The adapter
# never logs, stores, or returns file content or the daemon's signature name.
class AttachmentScanner::Clamd
  DEFAULT_ADDRESS = "tcp://127.0.0.1:3310"
  CONNECT_TIMEOUT = 3
  IO_TIMEOUT = 30
  CHUNK_BYTES = 64 * 1024
  MAX_REPLY_BYTES = 512

  attr_reader :address

  def initialize(address: nil, connect_timeout: CONNECT_TIMEOUT, io_timeout: IO_TIMEOUT)
    @address = parse_address(address.presence || DEFAULT_ADDRESS)
    @connect_timeout = connect_timeout
    @io_timeout = io_timeout
  end

  def scan(data:, content_type:, filename:)
    reply = with_socket { |socket| stream(socket, data.to_s.b) }
    interpret(reply)
  rescue Timeout::Error, IOError, SystemCallError, SocketError => error
    Rails.logger.warn("clamd scan unavailable: #{error.class}")
    unavailable("scanner_unavailable")
  end

  private
    def parse_address(value)
      case value
      when %r{\Aunix://(/.+)\z}
        { unix: Regexp.last_match(1) }
      when %r{\A(?:tcp://)?\[?([^\[\]/]+?)\]?:(\d{1,5})\z}
        host, port = Regexp.last_match(1), Integer(Regexp.last_match(2))
        raise AttachmentScanner::ConfigurationError, "clamd port out of range" unless port.between?(1, 65_535)

        { host:, port: }
      else
        raise AttachmentScanner::ConfigurationError, "clamd address must be tcp://host:port or unix:///path"
      end
    end

    def with_socket
      socket = if @address[:unix]
        Timeout.timeout(@connect_timeout) { UNIXSocket.new(@address[:unix]) }
      else
        Socket.tcp(@address[:host], @address[:port], connect_timeout: @connect_timeout)
      end
      socket.binmode
      yield socket
    ensure
      socket&.close
    end

    def stream(socket, data)
      write(socket, "zINSTREAM\0")
      offset = 0
      while offset < data.bytesize
        chunk = data.byteslice(offset, CHUNK_BYTES)
        write(socket, [ chunk.bytesize ].pack("N") + chunk)
        offset += chunk.bytesize
      end
      write(socket, [ 0 ].pack("N"))
      read_reply(socket)
    end

    def write(socket, bytes)
      until bytes.empty?
        written = socket.write_nonblock(bytes, exception: false)
        if written == :wait_writable
          raise Timeout::Error, "clamd write timed out" unless socket.wait_writable(@io_timeout)
          next
        end
        bytes = bytes.byteslice(written..)
      end
    end

    def read_reply(socket)
      reply = +"".b
      loop do
        raise Timeout::Error, "clamd read timed out" unless socket.wait_readable(@io_timeout)

        part = socket.read_nonblock(MAX_REPLY_BYTES, exception: false)
        raise IOError, "clamd closed the connection" if part.nil?
        next if part == :wait_readable

        reply << part
        return reply.chomp("\0") if reply.end_with?("\0")
        raise IOError, "clamd reply exceeded #{MAX_REPLY_BYTES} bytes" if reply.bytesize > MAX_REPLY_BYTES
      end
    end

    def interpret(reply)
      case reply
      when "stream: OK" then AttachmentScanner::Result.new(status: :clean, code: "clamd_clean")
      when /\Astream: .+ FOUND\z/ then AttachmentScanner::Result.new(status: :infected, code: "clamd_found")
      when /size limit exceeded/i then unavailable("clamd_size_limit")
      else unavailable("clamd_protocol_error")
      end
    end

    def unavailable(code)
      AttachmentScanner::Result.new(status: :unavailable, code:)
    end
end
