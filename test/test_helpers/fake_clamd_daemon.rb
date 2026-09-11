require "socket"

# A clamd stand-in that serves one INSTREAM scan per connection and answers each
# with the next queued reply, so a test can script clean and infected outcomes.
class FakeClamdDaemon
  attr_reader :port, :streams

  def initialize(replies)
    @replies = replies.dup
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @streams = []
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  def address
    "tcp://127.0.0.1:#{port}"
  end

  def close
    @thread.kill
    @server.close
  end

  private
    def serve(client)
      client.binmode
      return client.close unless client.read(10) == "zINSTREAM\0"

      data = +"".b
      loop do
        length = client.read(4).unpack1("N")
        break if length.zero?

        data << client.read(length)
      end
      @streams << data
      client.write(@replies.shift || "stream: OK\0")
    rescue IOError, SystemCallError
      nil
    ensure
      client.close
    end
end
