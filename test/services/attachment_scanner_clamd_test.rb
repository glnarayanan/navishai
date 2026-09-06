require "test_helper"
require "socket"

class AttachmentScannerClamdTest < ActiveSupport::TestCase
  # A minimal clamd stand-in that records the streamed bytes and answers with a canned reply.
  class FakeClamd
    attr_reader :received, :port

    def initialize(reply:, stall: false)
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @reply = reply
      @stall = stall
      @received = +"".b
      @thread = Thread.new { serve }
    end

    def close
      @server.close
      @thread.join(2)
    end

    private
      def serve
        client = @server.accept
        client.binmode
        command = client.readpartial(10)
        return client.close unless command == "zINSTREAM\0"

        loop do
          length = client.read(4).unpack1("N")
          break if length.zero?

          @received << client.read(length)
        end
        sleep 5 if @stall
        client.write(@reply)
      rescue IOError, Errno::ECONNRESET
        nil
      ensure
        client&.close
      end
  end

  test "an explicit OK reply marks the file clean after streaming every byte" do
    payload = "%PDF-1.7\n" + ("x" * (150 * 1024))
    daemon = FakeClamd.new(reply: "stream: OK\0")
    result = scanner(daemon).scan(data: payload, content_type: "application/pdf", filename: "report.pdf")
    daemon.close

    assert_equal :clean, result.status
    assert_equal "clamd_clean", result.code
    assert_equal payload.b, daemon.received
  end

  test "a FOUND reply marks the file infected without exposing the signature name" do
    daemon = FakeClamd.new(reply: "stream: Eicar-Test-Signature FOUND\0")
    result = scanner(daemon).scan(data: "X5O!", content_type: "text/plain", filename: "eicar.txt")
    daemon.close

    assert_equal :infected, result.status
    assert_equal "clamd_found", result.code
  end

  test "size-limit, unexpected, and unterminated replies stay unavailable" do
    [
      [ "INSTREAM size limit exceeded. ERROR\0", "clamd_size_limit" ],
      [ "stream: MAYBE\0", "clamd_protocol_error" ],
      [ "stream: OK", "scanner_unavailable" ]
    ].each do |reply, expected_code|
      daemon = FakeClamd.new(reply: reply)
      result = scanner(daemon).scan(data: "hello", content_type: "text/plain", filename: "note.txt")
      daemon.close

      assert_equal :unavailable, result.status, reply.inspect
      assert_equal expected_code, result.code
    end
  end

  test "an unreachable daemon or a stalled reply fails closed" do
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.addr[1]
    closed.close
    result = AttachmentScanner::Clamd.new(address: "tcp://127.0.0.1:#{port}", connect_timeout: 1)
      .scan(data: "hello", content_type: "text/plain", filename: "note.txt")
    assert_equal :unavailable, result.status
    assert_equal "scanner_unavailable", result.code

    daemon = FakeClamd.new(reply: "stream: OK\0", stall: true)
    result = AttachmentScanner::Clamd.new(address: "127.0.0.1:#{daemon.port}", io_timeout: 0.2)
      .scan(data: "hello", content_type: "text/plain", filename: "note.txt")
    daemon.close
    assert_equal :unavailable, result.status
    assert_equal "scanner_unavailable", result.code
  end

  test "intake keeps a clamd-clean file available and a found file rejected" do
    daemon = FakeClamd.new(reply: "stream: OK\0")
    prepared = AttachmentIntake.prepare!([ { filename: "note.txt", data: "safe text" } ], scanner: scanner(daemon))
    daemon.close
    attachment = AttachmentIntake.persist!(workspace: workspaces(:acme_support), prepared: prepared, source: :inbound_email).sole
    assert attachment.available?
    assert_equal "clamd_clean", attachment.scan_result_code

    daemon = FakeClamd.new(reply: "stream: Eicar-Test-Signature FOUND\0")
    prepared = AttachmentIntake.prepare!([ { filename: "note.txt", data: "unsafe" } ], scanner: scanner(daemon))
    daemon.close
    attachment = AttachmentIntake.persist!(workspace: workspaces(:acme_support), prepared: prepared, source: :inbound_email).sole
    assert attachment.rejected?
    assert_equal "clamd_found", attachment.scan_result_code
  end

  test "environment selection keeps the fail-closed default and rejects unknown scanners" do
    assert_instance_of AttachmentScanner, AttachmentScanner.from_environment({})
    assert_instance_of AttachmentScanner, AttachmentScanner.from_environment({ "NAVISHAI_ATTACHMENT_SCANNER" => " none " })

    clamd = AttachmentScanner.from_environment({ "NAVISHAI_ATTACHMENT_SCANNER" => "clamd" })
    assert_instance_of AttachmentScanner::Clamd, clamd
    assert_equal({ host: "127.0.0.1", port: 3310 }, clamd.address)

    unix = AttachmentScanner.from_environment(
      { "NAVISHAI_ATTACHMENT_SCANNER" => "clamd", "NAVISHAI_CLAMD_ADDRESS" => "unix:///run/clamav/clamd.ctl" }
    )
    assert_equal({ unix: "/run/clamav/clamd.ctl" }, unix.address)

    assert_raises(AttachmentScanner::ConfigurationError) do
      AttachmentScanner.from_environment({ "NAVISHAI_ATTACHMENT_SCANNER" => "shell" })
    end
    assert_raises(AttachmentScanner::ConfigurationError) do
      AttachmentScanner::Clamd.new(address: "http://clamav.example")
    end
    assert_raises(AttachmentScanner::ConfigurationError) do
      AttachmentScanner::Clamd.new(address: "tcp://clamav:70000")
    end
  end

  private
    def scanner(daemon)
      AttachmentScanner::Clamd.new(address: "tcp://127.0.0.1:#{daemon.port}", connect_timeout: 1, io_timeout: 2)
    end
end
