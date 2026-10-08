require "minitest/autorun"
require "json"
require "open3"
require "shellwords"
require "tmpdir"
require "pty"
require "timeout"

class VpsSetupTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  ANSWERS = {
    host: "lab.example.com", acme_email: "acme@example.com", smtp_server: "smtp.example.com",
    smtp_port: "587", smtp_user: "smtp-private-user", smtp_password: "smtp-private-password",
    smtp_from: "mail@example.com", owner_email: "owner@example.com",
    owner_password: "owner-private-password", owner_password_confirmation: "owner-private-password",
    organization_name: "Example Org", organization_slug: "example-org",
    workspace_name: "Support Lab", workspace_slug: "support-lab"
  }.freeze

  def setup
    @directory = Open3.capture2("sudo", "mktemp", "-d", "/tmp/navishai-setup-test.XXXXXXXX").first.strip
    @answers = "#{@directory}/answers.json"
    write_answers(JSON.generate(ANSWERS))
    Open3.capture3("sudo", "tee", "#{@directory}/SOURCE_COMMIT", stdin_data: "#{'a' * 40}\n")
  end

  def teardown
    system("sudo", "rm", "-rf", "--", @directory)
  end

  def test_protected_answers_generate_private_env_and_stdin_only_account
    output, status = run_setup
    assert status.success?, output
    assert_includes output, "Review nonsecret"
    assert_includes output, "INSTALL:600"
    assert_includes output, "COMPOSE:exec -T web bin/rails runner ops/vps/bootstrap_owner.rb"
    refute_includes output, "COMPOSE:run"
    assert_operator output.index("Review"), :<, output.index("INSTALL")
    assert_operator output.index("LOCK"), :<, output.index("COMPOSE")
    assert_redacted(output)
  end

  def test_invalid_unknown_missing_duplicate_and_unsafe_answers_do_not_install
    inputs = [ ANSWERS.merge(extra: "no"), ANSWERS.reject { |key, _| key == :smtp_from },
      ANSWERS.merge(smtp_password: "bad'quote"), ANSWERS.merge(smtp_password: 'bad\escape'),
      ANSWERS.merge(owner_password_confirmation: "different-password"), ANSWERS.merge(smtp_port: "0"),
      ANSWERS.merge(smtp_port: "0587"), ANSWERS.merge(smtp_port: "010"),
      ANSWERS.merge(owner_password: "short"), ANSWERS.merge(workspace_slug: "Bad Slug"),
      ANSWERS.merge(owner_email: "not-mail"), ANSWERS.merge(smtp_user: "line\nline") ]
    inputs.map { |data| JSON.generate(data) }.push(JSON.generate(ANSWERS).sub("{", '{"host":"duplicate.example.com",')).each do |json|
      write_answers(json)
      output, status = run_setup
      refute status.success?, output
      refute_includes output, "INSTALL"
      refute_includes output, "COMPOSE"
      assert_redacted(output)
    end
  end

  def test_shell_metacharacters_in_smtp_secret_stay_literal_and_private
    secret = 'literal$"`# secret'
    write_answers(JSON.generate(ANSWERS.merge(smtp_password: secret)))
    output, status = run_setup(<<~SH)
      vps_install() {
        vps_private "$envfile" || return 1
        grep -Fq #{Shellwords.escape("NAVISHAI_SYSTEM_SMTP_PASSWORD='#{secret}'")} "$envfile" || return 1
        echo INSTALL:600
      }
    SH
    assert status.success?, output
    assert_includes output, "INSTALL:600"
    refute_includes output, secret
  end

  def test_file_permissions_links_and_ancestry_are_checked
    system("sudo", "chmod", "0644", @answers)
    refute run_setup.last.success?
    system("sudo", "chmod", "0600", @answers)
    system("sudo", "ln", @answers, "#{@directory}/link")
    refute run_setup.last.success?
    system("sudo", "rm", "#{@directory}/link")
    system("sudo", "ln", "-s", @directory, "#{@directory}/alias")
    refute run_setup("answers=#{Shellwords.escape(@directory)}/alias/answers.json").last.success?
    system("sudo", "rm", "#{@directory}/alias")
    system("sudo", "chmod", "0777", @directory)
    refute run_setup.last.success?
  end

  def test_noninteractive_requires_explicit_protected_answers
    output, status = run_setup("answers=; non_interactive=true")
    refute status.success?
    refute_includes output, "INSTALL"
    output, status = run_setup("non_interactive=false")
    refute status.success?
    assert_includes output, "requires --non-interactive"
  end

  def test_resume_retains_config_and_never_generates_env
    before, = Open3.capture2("sudo", "sha256sum", @answers)
    output, status = run_setup("resume=true; vps_init_env() { echo MUST-NOT-GENERATE; return 1; }")
    assert status.success?, output
    assert_includes output, "RESUME"
    refute_includes output, "INSTALL"
    refute_includes output, "MUST-NOT-GENERATE"
    assert_redacted(output)
    after, = Open3.capture2("sudo", "sha256sum", @answers)
    assert_equal before, after
  end

  def test_resume_uses_retained_deliberate_ingress_and_refuses_unbacked_change
    script = <<~SH
      resume=true
      vps_load() { NAVISHAI_PUBLIC_LISTEN_ADDRESS=198.51.100.23; }
      vps_resolve_ingress() { [[ $1 == 198.51.100.23 ]] || return 7; export VPS_PUBLIC_LISTEN_ADDRESS="$1"; }
    SH
    output, status = run_setup(script)
    assert status.success?, output
    assert_includes output, "ingress: 198.51.100.23"
    output, status = run_setup(script + "listen_address=203.0.113.9")
    refute status.success?, output
    refute_includes output, "RESUME"
    refute_includes output, "COMPOSE"
  end

  def test_failed_install_offers_resume_and_does_not_bootstrap
    output, status = run_setup("vps_install() { return 1; }")
    refute status.success?
    assert_includes output, "install --resume"
    refute_includes output, "COMPOSE"
    assert_redacted(output)
  end

  def test_busy_mutation_lock_refuses_owner_setup_after_startup
    output, status = run_setup("vps_lock() { return 7; }")
    refute status.success?, output
    assert_includes output, "INSTALL:600"
    refute_includes output, "COMPOSE"
    assert_redacted(output)
  end

  def test_real_terminal_hidden_password_correction_and_review_cancellation
    transcript = terminal_flow(consent: "no", correction: true)
    assert_includes transcript, "Invalid host"
    assert_includes transcript, "Cancelled"
    refute_includes transcript, "INSTALL"
    refute_includes transcript, ANSWERS[:smtp_password]
    refute_includes transcript, ANSWERS[:owner_password]
  end

  def test_real_terminal_acceptance_and_eof
    transcript = terminal_flow(consent: "yes")
    assert_includes transcript, "INSTALL:600"
    refute_includes transcript, ANSWERS[:owner_password]
    output = +""
    PTY.spawn("sudo", "bash", "-c", script("answers=; non_interactive=false")) do |reader, writer, _pid|
      Timeout.timeout(10) do
        output << reader.readpartial(4096) until output.include?("host: ")
        writer.write("\x04")
        begin
          loop { output << reader.readpartial(4096) }
        rescue Errno::EIO, EOFError
        end
      end
    end
    refute_includes output, "INSTALL"
  end

  private
    def write_answers(json)
      Open3.capture3("sudo", "tee", @answers, stdin_data: json)
      system("sudo", "chmod", "0600", @answers)
    end

    def assert_redacted(output)
      %i[smtp_user smtp_password owner_password].each { |key| refute_includes output, ANSWERS[key] }
    end

    def script(extra = "")
      <<~BASH
        set -euo pipefail
        source #{Shellwords.escape(ROOT)}/ops/vps/cli.sh
        source #{Shellwords.escape(ROOT)}/ops/vps/setup.sh
        answers=#{Shellwords.escape(@answers)}; non_interactive=true; resume=false
        VPS_RELEASE=#{Shellwords.escape(@directory)}; commit=
        vps_resolve_ingress() { [[ $1 == auto ]]; export VPS_PUBLIC_LISTEN_ADDRESS=203.0.113.9; }
        vps_install() {
          vps_private "$envfile" || return 1
          ! grep -q owner-private "$envfile" || return 1
          grep -q "NAVISHAI_SYSTEM_SMTP_PASSWORD='smtp-private-password'" "$envfile" || return 1
          echo "INSTALL:$(stat -c %a "$envfile")"
        }
        vps_resume() { echo RESUME; }
        vps_load() { :; }
        vps_lock() { echo LOCK; }
        vps_compose() {
          echo "COMPOSE:$*"
          jq -e '.password == "owner-private-password" and .organization_slug == "example-org"' >/dev/null
        }
        #{extra}
        vps_setup
      BASH
    end

    def run_setup(extra = "")
      output, status = Open3.capture2e("sudo", "bash", "-c", script(extra))
      [ output, status ]
    end

    def terminal_flow(consent:, correction: false)
      transcript = +""
      PTY.spawn("sudo", "bash", "-c", script("answers=; non_interactive=false")) do |reader, writer, _pid|
        Timeout.timeout(20) do
          ANSWERS.each do |key, value|
            transcript << reader.readpartial(4096) until transcript.end_with?("#{key}: ")
            if correction && key == :host
              writer.puts "bad"
              transcript << reader.readpartial(4096) until transcript.include?("Invalid host") && transcript.end_with?("host: ")
            end
            writer.puts value
          end
          transcript << reader.readpartial(4096) until transcript.end_with?("continue: ")
          writer.puts consent
          begin
            loop { transcript << reader.readpartial(4096) }
          rescue Errno::EIO, EOFError
          end
        end
      end
      transcript
    end
end
