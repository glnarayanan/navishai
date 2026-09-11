require "test_helper"
require_relative "../test_helpers/fake_clamd_daemon"

class AttachmentScannerCheckTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
  end

  test "records a pass when the clean fixture is clean and the test signature is detected" do
    daemon = FakeClamdDaemon.new([ "stream: OK\0", "stream: Eicar-Test-Signature FOUND\0" ])
    outcome = with_scanner(daemon) { AttachmentScannerCheck.run!(workspace: @workspace, membership: @owner) }
    daemon.close

    assert_equal "passed", outcome.result
    assert_equal "synthetic_scan_passed", outcome.result_code
    assert_equal "attachment_scanner", outcome.check.check_kind
    assert_equal @owner, outcome.check.recorded_by_membership
    assert_equal AttachmentScannerCheck::CLEAN_FIXTURE.b, daemon.streams.first
    assert_equal AttachmentScannerCheck::EICAR_PARTS.join.b, daemon.streams.last
    assert AuditEvent.exists?(action: "operations.check_recorded", subject_type: "OperationalCheck", subject_id: outcome.check.id)
  end

  test "records failures for a rejected clean fixture or an undetected test signature" do
    rejected = FakeClamdDaemon.new([ "stream: Something FOUND\0", "stream: Something FOUND\0" ])
    outcome = with_scanner(rejected) { AttachmentScannerCheck.run!(workspace: @workspace, membership: @owner) }
    rejected.close
    assert_equal [ "failed", "clean_fixture_rejected" ], [ outcome.result, outcome.result_code ]

    blind = FakeClamdDaemon.new([ "stream: OK\0", "stream: OK\0" ])
    outcome = with_scanner(blind) { AttachmentScannerCheck.run!(workspace: @workspace, membership: @owner) }
    blind.close
    assert_equal [ "failed", "test_signature_not_detected" ], [ outcome.result, outcome.result_code ]
  end

  test "records unavailable without raising when the daemon cannot be reached" do
    daemon = FakeClamdDaemon.new([])
    daemon.close
    outcome = with_scanner(daemon) { AttachmentScannerCheck.run!(workspace: @workspace, membership: @owner) }

    assert_equal "unavailable", outcome.result
    assert_equal "scanner_unavailable", outcome.result_code
  end

  test "binds the recorded check to the scanner configuration and requires a source version" do
    daemon = FakeClamdDaemon.new([ "stream: OK\0", "stream: X FOUND\0" ])
    outcome = with_scanner(daemon) { AttachmentScannerCheck.run!(workspace: @workspace, membership: @owner) }
    with_scanner(daemon) do
      assert_equal outcome.check, AttachmentScannerCheck.latest_for_current_configuration(@workspace)
    end
    with_scanner(daemon, address: "tcp://127.0.0.1:1") do
      assert_nil AttachmentScannerCheck.latest_for_current_configuration(@workspace)
    end
    with_scanner(daemon, source_commit: "") do
      assert_raises(AttachmentScannerCheck::SourceCommitUnavailable) { AttachmentScannerCheck.run!(workspace: @workspace, membership: @owner) }
    end
    daemon.close
  end

  test "refuses to run without a configured scanner and never scans for a viewer" do
    assert_raises(AttachmentScannerCheck::NotConfigured) { AttachmentScannerCheck.run!(workspace: @workspace, membership: @owner) }

    daemon = FakeClamdDaemon.new([ "stream: OK\0", "stream: X FOUND\0" ])
    viewer = @workspace.memberships.create!(user: users(:outsider), role: :viewer)
    with_scanner(daemon) do
      assert_raises(Current::RoleAccessDenied) { AttachmentScannerCheck.run!(workspace: @workspace, membership: viewer) }
    end
    daemon.close
    assert_equal 0, OperationalCheck.where(check_kind: "attachment_scanner").count
  end

  private
    def with_scanner(daemon, address: daemon.address, source_commit: "c" * 40)
      original = ENV.to_h.slice("NAVISHAI_ATTACHMENT_SCANNER", "NAVISHAI_CLAMD_ADDRESS", "NAVISHAI_SOURCE_COMMIT")
      ENV["NAVISHAI_ATTACHMENT_SCANNER"] = "clamd"
      ENV["NAVISHAI_CLAMD_ADDRESS"] = address
      ENV["NAVISHAI_SOURCE_COMMIT"] = source_commit
      yield
    ensure
      %w[NAVISHAI_ATTACHMENT_SCANNER NAVISHAI_CLAMD_ADDRESS NAVISHAI_SOURCE_COMMIT].each do |key|
        original.key?(key) ? ENV[key] = original[key] : ENV.delete(key)
      end
    end
end
