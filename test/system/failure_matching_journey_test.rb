require "application_system_test_case"
require_relative "../support/failure_matching_fixture"

class FailureMatchingJourneyTest < ApplicationSystemTestCase
  include FailureMatchingFixture

  test "expert inspects conflict appends history and sees retained stale error empty and viewer states" do
    build_failure_matching_fixture
    sign_in users(:owner)
    visit source_path
    assert_text "Exact shared terms:"
    assert_text "Conflicting known facts — review caution"
    select "Match", from: "Decision for scenario #{@version.scenario_id} v1"
    fill_in "Reason for this association", with: "Certificate failure overlaps; plan differs."
    click_button "Append trace decision"
    assert_text "Trace decision appended"
    select "Uncertain", from: "Decision for scenario #{@version.scenario_id} v1"
    fill_in "Reason for this association", with: "Need logs before treating these as the same issue."
    click_button "Append trace decision"
    assert_text "Trace decision appended"
    assert_text "Earlier decision"
    [ 1280, 390 ].each { |width| capture("conflicts-history-#{width}", width) }
    @version.scenario.revise!(membership: @membership, base_version_id: @version.id, attributes: { title: "Updated certificate diagnostics" })
    fill_in "Reason for this association", with: "Keep my stale explanation."
    click_button "Append trace decision"
    assert_selector "[role=alert]", text: "Choose a current"
    assert_text "Keep my stale explanation."
    [ 1280, 390 ].each { |width| capture("retained-error-#{width}", width) }
    @version.scenario.reload.current_version.scenario.review!(membership: @membership, version_id: @version.scenario.current_version_id, decision: "reject")
    visit source_path
    assert_text "No candidates share at least two meaningful terms"
    capture("empty-390", 390)
    Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :viewer)
    find(".lab-navigation summary").click
    click_button "Sign out"
    sign_in users(:teammate)
    visit source_path
    assert_no_button "Append trace decision"
    assert_text "Expert associations and history"
    capture("viewer-390", 390)
  end

  private
    def source_path
      workspace_corpus_source_path(@corpus.workspace, @corpus, @item.source_snapshot.source)
    end

    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/failure-matching/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
