require "application_system_test_case"
require_relative "../test_helpers/scenario_test_helper"

class ScenarioJourneyTest < ApplicationSystemTestCase
  include ScenarioTestHelper

  test "expert corrects evidence backed scenario approves a version and varies one fact" do
    build_scenarios
    sign_in users(:owner)
    visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
    click_button "Create selected scenarios"
    assert_selector "h1", text: "Scenarios"
    click_link @scenario.current_version.title
    fill_in "Customer starting situation", with: "Customer cannot sign in after rotating their SAML certificate."
    fill_in "Outcomes — one requirement per line", with: "Identify certificate expiry as a possible cause."
    fill_in "Actions — one requirement per line", with: "Request the certificate expiry date."
    find("summary", text: "Attach company documentation").click
    select "SSO playbook", from: "Company document"
    select "Knowledge available to target", from: "Evidence use"
    fill_in "Exact document excerpt", with: "Request the certificate expiry date."
    click_button "Save new version"
    assert_text "Version 2 · expert · needs review"
    click_button "Save expert decision"
    assert_text "Version 2 · expert · approve"
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1600)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("review-#{width}")
    end
    find("summary", text: "Create a controlled variant").click
    select "plan", from: "Fact to change"
    fill_in "New value (JSON, including quotes for text)", with: '"starter"'
    fill_in "Why this change matters", with: "SSO needs enterprise."
    fill_in "Expected behaviour difference", with: "Explain the plan limit."
    click_button "Create variant"
    assert_text "Version 1 · variant · needs review"
    assert_text "Variant of"
    assert_text '"after": "starter"'
    capture("variant-390")
    click_button "Save expert decision"
    assert_selector "[role=alert]", text: /revise the variant/
    assert_text "Version 1 · variant · needs review"
    capture("blocked-390")
    fill_in "Customer starting situation", with: "A starter-plan customer asks how to enable SAML."
    fill_in "Outcomes — one requirement per line", with: "Explain the enterprise plan requirement."
    click_button "Save new version"
    assert_text "Version 2 · expert · needs review"
    click_button "Save expert decision"
    assert_text "Version 2 · expert · approve"
    click_link "Version 1"
    assert_text "Version 1 · variant · needs review"
    assert_no_horizontal_overflow
    assert_no_csp_violations
  end

  private
    def capture(name)
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/scenarios/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
