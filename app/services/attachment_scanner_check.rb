# Owner-triggered synthetic check of the configured attachment scanner.
#
# It streams two fixtures through the deployment's scanner: a known-clean text
# file that must come back clean, and the EICAR test signature that every
# daemon with signatures must report as infected. The outcome is recorded as an
# append-only OperationalCheck bound to a digest of the scanner configuration,
# so the checklist can say "tested" only for the configuration that passed.
# A pass proves reachability and classification of the standard test signature.
# It does not prove real-malware coverage, signature freshness, or intake
# behaviour, and it never changes quarantine state.
class AttachmentScannerCheck
  class NotConfigured < StandardError; end
  class SourceCommitUnavailable < StandardError; end

  CHECK_KIND = "attachment_scanner".freeze
  FRESH_FOR = 30.days
  CLEAN_FIXTURE = "NavishAI attachment scanner check: this plain-text fixture must be reported clean.\n".freeze
  # Assembled at runtime so the repository never contains the literal test string.
  EICAR_PARTS = [ "X5O!P%@AP[4\\PZX54(P^)7CC)7}$", "EICAR-STANDARD-", "ANTIVIRUS-TEST-FILE!$H+H*" ].freeze

  Outcome = Data.define(:result, :result_code, :check)

  def self.configuration_digest(env = ENV)
    Digest::SHA256.hexdigest([ env["NAVISHAI_ATTACHMENT_SCANNER"].to_s.strip.downcase, env["NAVISHAI_CLAMD_ADDRESS"].to_s.strip ].join("\n"))
  end

  def self.configured?(env = ENV)
    AttachmentScanner.from_environment(env).is_a?(AttachmentScanner::Clamd)
  rescue AttachmentScanner::ConfigurationError
    false
  end

  # The latest check for the currently configured scanner, or nil when the
  # configuration changed since the last check or no check exists.
  def self.latest_for_current_configuration(workspace, env = ENV)
    workspace.operational_checks.where(check_kind: CHECK_KIND, evidence_digest: configuration_digest(env)).latest_first.first
  end

  def self.run!(workspace:, membership:, env: ENV, now: Time.current)
    scanner = AttachmentScanner.from_environment(env)
    raise NotConfigured, "no attachment scanner is configured" unless scanner.is_a?(AttachmentScanner::Clamd)

    source_commit = env["NAVISHAI_SOURCE_COMMIT"].to_s
    raise SourceCommitUnavailable, "source_commit_unavailable" unless source_commit.match?(OperationalCheck::COMMIT_FORMAT)

    result, result_code = classify(
      scan(scanner, CLEAN_FIXTURE, "scanner-check-clean.txt"),
      scan(scanner, EICAR_PARTS.join, "scanner-check-signature.txt")
    )
    check = OperationalCheck.record!(
      workspace:, membership:, check_kind: CHECK_KIND, result:, result_code:,
      evidence_digest: configuration_digest(env), source_commit:, checked_at: now
    )
    Outcome.new(result:, result_code:, check:)
  end

  def self.classify(clean, signature)
    return [ "unavailable", clean.code.to_s ] if clean.status.to_sym == :unavailable
    return [ "unavailable", signature.code.to_s ] if signature.status.to_sym == :unavailable
    return [ "failed", "clean_fixture_rejected" ] unless clean.status.to_sym == :clean
    return [ "failed", "test_signature_not_detected" ] unless signature.status.to_sym == :infected

    [ "passed", "synthetic_scan_passed" ]
  end
  private_class_method :classify

  def self.scan(scanner, data, filename)
    result = scanner.scan(data: data.b, content_type: "text/plain", filename: filename)
    raise ArgumentError, "invalid scanner result" unless result.is_a?(AttachmentScanner::Result) && result.code.present?

    result
  rescue StandardError => error
    Rails.logger.error("Attachment scanner check failed closed: #{error.class}")
    AttachmentScanner::Result.new(status: :unavailable, code: "scanner_unavailable")
  end
  private_class_method :scan
end
