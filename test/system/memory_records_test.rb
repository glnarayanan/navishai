require "application_system_test_case"

class MemoryRecordsTest < ApplicationSystemTestCase
  test "a manager inspects, corrects, and deletes scoped memory on desktop and mobile" do
    workspace = workspaces(:acme_support)
    memory = workspace.memory_records.create!(
      memory_type: :profile, scope_kind: :workspace, topic: "contact-window",
      content: "Customer prefers morning contact.", authority: :source_record, origin_kind: :system,
      source_reference: "test://contact-window", source_digest: Digest::SHA256.hexdigest("morning"),
      observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 0.8, retention_policy: :indefinite
    )
    sign_in(users(:owner))
    visit workspace_support_cases_path(workspace)
    click_link "Memory", match: :first

    assert_text "Workspace memory"
    assert_text "Customer prefers morning contact."
    find(".memory-record-link", text: "Customer prefers morning contact.").click
    assert_text "Source record"
    assert_text "memory://#{memory.memory_key}"

    fill_in "Corrected context", with: "Customer prefers contact after 14:00 UTC."
    fill_in "Confidence", with: "0.95"
    click_button "Publish correction"
    assert_text "Correction published."
    assert_text "Superseded"
    corrected = memory.reload.revisions.sole
    click_link corrected.memory_key
    assert_text "Customer prefers contact after 14:00 UTC."
    assert_text "Human correction"

    page.current_window.resize_to(320, 844)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_operator find_link("Memory", match: :first).rect.height, :>=, 48
    assert_operator find_field("Corrected context").rect.height, :>=, 48
    assert_operator find_button("Publish correction").rect.height, :>=, 48
    save_screenshot Rails.root.join(".amp/in/artifacts/memory-record-mobile.png") if ENV["CAPTURE_MEMORY"]

    page.current_window.resize_to(1440, 1000)
    save_screenshot Rails.root.join(".amp/in/artifacts/memory-record-desktop.png") if ENV["CAPTURE_MEMORY"]

    fill_in "Deletion reason", with: "Customer asked us to remove this stored preference."
    accept_confirm { click_button "Delete memory" }
    assert_text "Memory removed from current use."
    assert_text "Deleted from retrieval"
    assert_text "Customer asked us to remove this stored preference."
  end

  private
    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_on "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end
end
