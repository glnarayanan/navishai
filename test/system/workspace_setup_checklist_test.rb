require "application_system_test_case"

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
end
