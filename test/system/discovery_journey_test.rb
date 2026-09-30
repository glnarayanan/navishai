require "application_system_test_case"

class DiscoveryJourneyTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  test "expert explores discovered clusters corrects a label and sees versioned human authority" do
    corpus = workspaces(:acme_support).corpora.create!(name: "Technical corpus")
    CorpusIntake.call(corpus:, membership: memberships(:owner_support), name: "Export", kind: "conversations", bytes: Rails.root.join("test/fixtures/files/support_export.json").read)
    sign_in users(:owner)
    visit workspace_corpus_path(corpus.workspace, corpus)
    fill_in "Candidate limit", with: 2
    click_button "Analyse corpus locally"
    assert_selector "h1", text: "Corpus analysis"
    assert_text "Waiting for the local processing job"
    perform_enqueued_jobs
    click_link "Refresh result"
    assert_text "2 candidates selected from 2 conversations"
    first("details.source-record summary").click
    assert_text "Expert review required"
    first("input[name=label]").set("SSO certificate expiry")
    first("input[value='Save expert label']").click
    assert_text "expert revision 1"
    assert_selector "h2", text: "SSO certificate expiry"
    first("details.source-record summary").click
    assert_selector "a", text: "Inspect source snapshot"
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1600)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      if ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
        path = Rails.root.join(".amp/in/artifacts/discovery/review-#{width}.png")
        FileUtils.mkdir_p(path.dirname)
        save_screenshot(path)
      end
    end
  end
end
