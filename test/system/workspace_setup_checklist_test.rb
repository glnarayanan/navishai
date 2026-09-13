require "application_system_test_case"
require_relative "../test_helpers/fake_clamd_daemon"
require_relative "../test_helpers/fake_memory_engine"

class WorkspaceSetupChecklistTest < ApplicationSystemTestCase
  test "an Owner sees deferred deployment capabilities on desktop and mobile" do
    workspace = workspaces(:acme_support)
    sign_in(users(:owner))
    visit workspace_setup_checklist_path(workspace)

    assert_text "Setup checklist"
    assert_text "System email"
    assert_text "Set deployment SMTP"
    assert_text "Attachments"
    assert_text "Configure ClamAV"

    page.current_window.resize_to(390, 1400)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    system_mail = find("a[aria-label='Open System email']")
    assert_operator system_mail.rect.height, :>=, 48
    save_screenshot Rails.root.join(".amp/in/artifacts/setup-checklist-mobile.png") if ENV["CAPTURE_SETUP_CHECKLIST"]

    page.current_window.resize_to(1440, 1000)
    save_screenshot Rails.root.join(".amp/in/artifacts/setup-checklist-desktop.png") if ENV["CAPTURE_SETUP_CHECKLIST"]
  end

  test "an Owner verifies configured memory from the checklist" do
    workspace = workspaces(:acme_support)
    engine = FakeMemoryEngine.new
    original = SupermemoryEngine.method(:default)
    SupermemoryEngine.define_singleton_method(:default) { engine }
    env = ENV.to_h.slice("NAVISHAI_SUPERMEMORY_ADDRESS", "NAVISHAI_SUPERMEMORY_API_KEY", "NAVISHAI_SOURCE_COMMIT", "NAVISHAI_MEMORY_PENDING")
    ENV["NAVISHAI_SUPERMEMORY_ADDRESS"] = "http://127.0.0.1:6767"
    ENV["NAVISHAI_SUPERMEMORY_API_KEY"] = "sm_#{"a" * 32}"
    ENV["NAVISHAI_SOURCE_COMMIT"] = "c" * 40
    ENV.delete("NAVISHAI_MEMORY_PENDING")

    sign_in(users(:owner))
    visit workspace_setup_checklist_path(workspace)
    assert_text "Self-hosted memory is configured but has not been verified"
    assert_selector "span.status-configured", text: "Configured"

    accept_confirm { click_button "Test memory" }
    assert_text "Memory verification passed"
    assert_selector "span.status-tested", text: "Tested"
    assert_text "Live service proof is separate"

    engine.index_status = "queued"
    accept_confirm { click_button "Test memory" }
    assert_text "not complete"
    refute_selector "span.status-tested"

    page.current_window.resize_to(390, 1400)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_operator find_button("Test memory").rect.height, :>=, 44

    page.current_window.resize_to(320, 1400)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
  ensure
    SupermemoryEngine.define_singleton_method(:default, original) if original
    %w[NAVISHAI_SUPERMEMORY_ADDRESS NAVISHAI_SUPERMEMORY_API_KEY NAVISHAI_SOURCE_COMMIT NAVISHAI_MEMORY_PENDING].each do |key|
      env&.key?(key) ? ENV[key] = env[key] : ENV.delete(key)
    end
  end

  test "an Owner tests a configured scanner from the checklist and sees the honest result" do
    workspace = workspaces(:acme_support)
    daemon = FakeClamdDaemon.new([ "stream: OK\0", "stream: Eicar-Test-Signature FOUND\0" ])
    original = ENV.to_h.slice("NAVISHAI_ATTACHMENT_SCANNER", "NAVISHAI_CLAMD_ADDRESS", "NAVISHAI_SOURCE_COMMIT")
    ENV["NAVISHAI_ATTACHMENT_SCANNER"] = "clamd"
    ENV["NAVISHAI_CLAMD_ADDRESS"] = daemon.address
    ENV["NAVISHAI_SOURCE_COMMIT"] = "c" * 40

    sign_in(users(:owner))
    visit workspace_setup_checklist_path(workspace)
    assert_text "ClamAV is configured but has not been tested"
    assert_selector "span.status-configured", text: "Configured"

    accept_confirm { click_button "Test scanner" }

    assert_text "Scanner test passed"
    assert_selector "span.status-tested", text: "Tested"
    assert_text "not real-malware coverage"

    page.current_window.resize_to(390, 1400)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_operator find_button("Test scanner").rect.height, :>=, 44
  ensure
    daemon&.close
    %w[NAVISHAI_ATTACHMENT_SCANNER NAVISHAI_CLAMD_ADDRESS NAVISHAI_SOURCE_COMMIT].each do |key|
      original.key?(key) ? ENV[key] = original[key] : ENV.delete(key)
    end
  end
end
