require "application_system_test_case"
require_relative "../test_helpers/scenario_test_helper"

class ScenarioJourneyTest < ApplicationSystemTestCase
  include ScenarioTestHelper

  test "expert finds current scenarios and recovers from empty and invalid local searches" do
    build_scenarios
    version = @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { title: "Signing certificate expiry", situation: "Inspect rotated signing metadata.", taxonomy_label: "Identity diagnostics" })
    sign_in users(:owner)
    visit workspace_corpus_scenarios_path(@workspace, @corpus)
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1000)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("search-all-#{width}")
    end
    fill_in "Scenario search phrase", with: "CeRtIfIcAtE"
    find_field("Scenario search phrase").send_keys(:enter)
    assert_selector "#scenario-search [role=status]", text: "1 matching scenario"
    assert_selector ".workspace-card", count: 1
    assert_link "Signing certificate expiry", href: workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1000)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("search-matched-#{width}")
    end
    fill_in "Scenario search phrase", with: "An absent issue family"
    click_button "Find scenarios"
    assert_selector "#scenario-search [role=status]", text: "0 matching scenarios"
    assert_text "No scenarios on this page"
    assert_no_selector ".workspace-card"
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1000)
      assert_no_horizontal_overflow
      capture("search-empty-#{width}")
    end
    visit workspace_corpus_scenarios_path(@workspace, @corpus, corpus_query: "x" * 201)
    assert_selector "#scenario-search [role=alert]", text: "200 characters and no null bytes"
    assert_field "Scenario search phrase", with: "x" * 201
    assert_equal "true", find_field("Scenario search phrase")["aria-invalid"]
    assert_no_selector ".workspace-card"
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1000)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("search-error-#{width}")
    end
    click_link "Clear search"
    assert_field "Scenario search phrase", with: ""
    assert_selector "#scenario-search [role=status]", text: "2 matching scenarios"
    click_link "Signing certificate expiry"
    assert_selector "h1", text: "Signing certificate expiry"
    assert_equal version.id, @scenario.reload.current_version_id
    assert_empty version.scenario_reviews
  end

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
    find("summary", text: "Attach source evidence").click
    select "SSO playbook", from: "Source record"
    select "Knowledge available to target", from: "Evidence use"
    fill_in "Exact source excerpt", with: "Request the certificate expiry date."
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
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 2 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
