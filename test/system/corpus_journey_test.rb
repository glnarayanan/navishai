require "application_system_test_case"

class CorpusJourneyTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  test "expert repairs exact masking privately and inspects fixed rules and masked evidence" do
    workspace = workspaces(:acme_support)
    corpus = workspace.corpora.create!(name: "Exact masking fixture")
    sign_in users(:owner)
    visit workspace_corpus_path(workspace, corpus)
    fill_in "Source name", with: "Exact history"
    select "Mask exact text", from: "Redaction"
    fill_in "Text to mask (exact-text mode only)", with: "first@example.org\nsecond@example.org"
    attach_file "Company data file", Rails.root.join("test/fixtures/files/masked_key_collision_export.json")
    assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        find("input[value='Import source']").send_keys(:enter)
        assert_selector "[role=alert]", text: "Exact-text masking would merge distinct JSON keys. Rename those keys before upload; no records were imported."
        assert_equal "exact", find_field("Redaction").value
        assert_field "Text to mask (exact-text mode only)", with: ""
        assert_no_text "first@example.org"
        assert_no_text "second@example.org"
        [ 1280, 390, 320 ].each do |width|
          page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
          assert_no_horizontal_overflow
          assert_no_csp_violations
          capture("exact-repair-#{width}", selector: "[role=alert]")
          capture("exact-policy-#{width}", selector: "section:has(input[type=file])")
        end
      end
    end
    fill_in "Source name", with: "Exact history"
    fill_in "Text to mask (exact-text mode only)", with: "admin@example.org\ninvoices"
    attach_file "Company data file", Rails.root.join("test/fixtures/files/support_export.json")
    assert_difference [ "Source.count", "SourceSnapshot.count" ], 1 do
      assert_no_enqueued_jobs do
        find("input[value='Import source']").send_keys(:enter)
        assert_selector "h1", text: "Exact history"
        assert_text "Exact text masked"
        assert_text "2 unique values; the values themselves are not retained."
        assert_text "This is not approval to disclose data."
        assert_text "[text redacted]"
        assert_no_text "admin@example.org"
        [ 1280, 390, 320 ].each do |width|
          page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
          assert_no_horizontal_overflow
          assert_no_csp_violations
          capture("exact-source-#{width}", selector: "main")
        end
      end
    end
    snapshot = corpus.sources.find_by!(name: "Exact history").current_snapshot
    assert_equal 2, snapshot.mask_count
    assert_equal 2, snapshot.corpus_items.count
    assert_not_includes snapshot.attributes.to_json, "admin@example.org"
  end

  test "expert sees a private masking-collision repair while the retained source stays fixed" do
    workspace = workspaces(:acme_support)
    corpus = workspace.corpora.create!(name: "Intake integrity fixture")
    snapshot = CorpusIntake.call(corpus:, membership: memberships(:owner_support), name: "Support history", kind: "conversations",
      bytes: File.read(Rails.root.join("test/fixtures/files/support_export.json")))
    source_state = snapshot.source.reload.attributes
    sign_in users(:owner)
    visit workspace_corpus_path(workspace, corpus)
    fill_in "Source name", with: "Support history"
    attach_file "Company data file", Rails.root.join("test/fixtures/files/masked_key_collision_export.json")
    fill_in "Retention days", with: 2
    assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        find("input[value='Import source']").send_keys(:enter)
        assert_selector "[role=alert]", text: "Email masking would merge distinct JSON keys. Rename those keys before upload; no records were imported."
        assert_no_text "first@example.org"
        assert_no_text "second@example.org"
        [ 1280, 390 ].each do |width|
          page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
          assert_no_horizontal_overflow
          assert_no_csp_violations
          capture("masking-collision-#{width}", selector: "[role=alert]")
          capture("masking-policy-#{width}", selector: "section:has(input[type=file])")
        end
      end
    end
    assert_equal source_state, snapshot.source.reload.attributes
    click_link "Support history", match: :first
    assert_selector "h1", text: "Support history"
    assert_text "Snapshot 1"
    assert_text "support-export-v1"
    assert_no_selector "summary", text: "Snapshot 2"
    assert_equal snapshot.id, snapshot.source.reload.current_snapshot_id
  end

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
    def capture(name, selector: nil)
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/corpus/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      if selector
        width = page.evaluate_script("window.innerWidth")
        bounds = page.evaluate_script("(() => { const rect = document.querySelector(#{selector.to_json}).getBoundingClientRect(); return { top: rect.top + window.scrollY, bottom: rect.bottom + window.scrollY }; })()")
        top = [ bounds.fetch("top") - 12, 0 ].max.floor
        image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
          clip: { x: 0, y: top, width:, height: (bounds.fetch("bottom") - top + 12).ceil, scale: 1 })
        File.binwrite(path, Base64.decode64(image.fetch("data")))
      else
        save_screenshot(path)
      end
    end
end
