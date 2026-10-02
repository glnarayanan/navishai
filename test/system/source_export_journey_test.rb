require "application_system_test_case"
require_relative "../test_helpers/source_export_fixture"

class SourceExportJourneyTest < ApplicationSystemTestCase
  include SourceExportFixture

  test "retained download form exact history error and viewer states" do
    membership = memberships(:owner_support)
    workspace = membership.workspace
    corpus = workspace.corpora.create!(name: "Retained export fixture")
    old = export_snapshot(corpus:, membership:, count: 1)
    current = export_snapshot(corpus:, membership:, count: 1, marker: "current")
    source = old.source
    sign_in users(:owner)
    visit workspace_corpus_source_path(workspace, corpus, source)
    find("#source-download summary").click
    assert_selector "input[name=snapshot_id][value='#{current.id}']", visible: :all
    assert_text "Email masking is incomplete"
    assert_text "Downloaded copies fall outside local purge"
    [ 1280, 390 ].each { |width| capture("form-#{width}", width) }
    click_link "Snapshot 1", exact: true
    assert_selector "html:not([data-turbo-preview]):not([aria-busy=true])"
    assert_selector "#source-download summary", text: "Download retained snapshot 1"
    find("#source-download summary").click
    assert_selector "input[name=snapshot_id][value='#{old.id}']", visible: :all
    [ 1280, 390 ].each { |width| capture("historical-#{width}", width) }
    fill_in "Type Retained support to confirm download", with: "wrong 雪"
    click_button "Download snapshot 1 JSON"
    assert_selector "#source-download[open] [role=alert]", text: "Type the source name"
    assert_field "Type Retained support to confirm download", with: "wrong 雪"
    assert_selector "input[name=snapshot_id][value='#{old.id}']", visible: :all
    [ 1280, 390 ].each { |width| capture("error-#{width}", width) }
    Dir.mktmpdir("navishai-source-download-") do |directory|
      page.driver.browser.execute_cdp("Browser.setDownloadBehavior", behavior: "allow", downloadPath: directory)
      fill_in "Type Retained support to confirm download", with: source.name
      click_button "Download snapshot 1 JSON"
      path = File.join(directory, "source-#{source.id}-snapshot-#{old.id}.json")
      Timeout.timeout(10) { sleep 0.05 until File.exist?(path) && !File.exist?("#{path}.crdownload") }
      payload = JSON.parse(File.read(path))
      assert_equal "navishai-retained-source-v1", payload.fetch("format")
      assert_equal old.id, payload.fetch("snapshot").fetch("id")
      assert_equal 1, payload.fetch("records").length
      assert_equal "historical \"quoted\"\n\\ path 雪 [email redacted]", payload.fetch("records").sole.fetch("text")
      assert_equal 1, workspace.audit_events.where(action: "source.downloaded").count
    end
    workspace.memberships.create!(user: users(:teammate), role: :viewer)
    find("summary", text: "Navigation").click
    click_button "Sign out"
    sign_in users(:teammate)
    visit workspace_corpus_source_path(workspace, corpus, source, snapshot: 1)
    assert_no_selector "#source-download"
    [ 1280, 390 ].each { |width| capture("viewer-#{width}", width) }
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/source-export/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
