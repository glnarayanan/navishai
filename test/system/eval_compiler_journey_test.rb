require "application_system_test_case"
require_relative "../test_helpers/eval_test_helper"

class EvalCompilerJourneyTest < ApplicationSystemTestCase
  include EvalTestHelper

  test "expert defines graders compiles a case inspects visible input and assembles a suite" do
    build_eval_definitions
    sign_in users(:owner)
    empty_corpus = @workspace.corpora.create!(name: "New product corpus")
    visit workspace_corpus_graders_path(@workspace, empty_corpus)
    assert_text "No graders yet"
    visit workspace_corpus_graders_path(@workspace, @corpus)
    fill_in "Grader name", with: "Check collected expiry"
    select "Tool called", from: "Check type"
    fill_in "Check value", with: "collect_expiry"
    click_button "Create grader"
    assert_selector "h1", text: "Check collected expiry"
    assert_text "Version 1 · Deterministic"
    fill_in "Check value", with: ""
    click_button "Save grader version"
    assert_selector "[role=alert]", text: /selected versioned grader schema/
    assert_field "Check value", with: ""
    page.current_window.resize_to(390, 1600)
    capture("grader-error-390")
    visit workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    click_link "Compile eval"
    assert_selector "h1", text: "Compile eval"
    select "Certificate diagnosis · v1", from: "Grader for outcomes 1"
    select "Check collected expiry · v1", from: "Grader for actions 1"
    %w[outcomes actions].each { |kind| select "SSO stopped after certificate rotation · expectation", from: "Source for #{kind} 1" }
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1600)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("mapping-#{width}")
    end
    click_button "Compile fixed case"
    assert_text "definition 1 · support-contract-v1"
    case_path = page.current_path
    input = JSON.parse(find(".review-layout > section:nth-child(2) pre").text)
    assert_equal %w[knowledge known_facts situation], input.keys.sort
    assert_not_includes input.to_json, "private answer"
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1600)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("contract-#{width}")
    end
    click_link "Check collected expiry · version 1"
    fill_in "Check value", with: "collect_metadata"
    click_button "Save grader version"
    assert_text "Version 2 · Deterministic"
    visit case_path
    assert_link "Check collected expiry · version 1"
    click_link "Create an eval suite"
    fill_in "Suite name", with: "SSO readiness"
    click_button "Create suite"
    assert_selector "h1", text: "SSO readiness"
    visit case_path
    click_button "Add to SSO readiness"
    assert_selector "h1", text: "SSO readiness"
    assert_selector ".workspace-card", count: 1
    click_button "Remove case #{EvalCase.order(:id).last.id}"
    assert_selector ".workspace-card", count: 0
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "reject")
    visit new_workspace_corpus_eval_case_path(@workspace, @corpus, scenario_id: @scenario.id)
    assert_selector "[role=status]", text: /needs approval/
    assert_no_selector "input[value='Compile fixed case']"
    capture("blocked-390")
  end

  private
    def capture(name)
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/compiler/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
