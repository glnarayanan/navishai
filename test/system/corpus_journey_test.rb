require "application_system_test_case"

class CorpusJourneyTest < ApplicationSystemTestCase
  test "expert creates corpus imports redacted source and inspects evidence on desktop and mobile" do
    sign_in users(:owner)
    visit workspace_corpora_path(workspaces(:acme_support))
    fill_in "Corpus name", with: "Technical support"
    click_button "Create corpus"
    assert_selector "h1", text: "Technical support"
    fill_in "Source name", with: "Support history"
    attach_file "Company data file", Rails.root.join("test/fixtures/files/support_export.json")
    click_button "Import source"
    assert_selector "h1", text: "Support history"
    assert_text "[email redacted]"
    assert_no_text "admin@example.org"
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1800)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("source-#{width}")
    end
    click_link "Technical support"
    fill_in "Source name", with: "Empty export"
    attach_file "Company data file", Rails.root.join("test/fixtures/files/empty_export.json")
    click_button "Import source"
    assert_selector "[role=alert]", text: "An upload needs"
    assert_no_horizontal_overflow
    capture("import-error-390")
  end

  private
    def capture(name)
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/corpus/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      save_screenshot(path)
    end
end
