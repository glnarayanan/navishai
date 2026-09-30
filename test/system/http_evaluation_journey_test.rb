require "application_system_test_case"
require_relative "../test_helpers/evaluation_test_helper"
require_relative "../test_helpers/http_target_test_helper"

class HttpEvaluationJourneyTest < ApplicationSystemTestCase
  include EvaluationTestHelper
  include HttpTargetTestHelper

  test "HTTP setup disclosure block and unknown execution outcome have clear recovery without repeating a call" do
    build_evaluation
    sign_in users(:owner)
    with_endpoint_approval do
      visit workspace_corpus_evaluation_targets_path(@workspace, @corpus)
      select "HTTP · approved HTTPS endpoint", from: "Target adapter"
      fill_in "Target name", with: "Candidate HTTP agent"
      fill_in "Target configuration JSON", with: '{"endpoint":"https://not-approved.example.test/evaluate"}'
      click_button "Create target"
      assert_selector "[role=alert]", text: /not approved/
      assert_selector "select[name=adapter] option:checked", text: "HTTP · approved HTTPS endpoint"
      capture("unapproved-390", 390)
      fill_in "Target configuration JSON", with: { endpoint: HTTP_ENDPOINT }.to_json
      click_button "Create target"
      assert_selector "h1", text: "Candidate HTTP agent"
      assert_text "outside NavishAI only after you confirm"
      [ 1280, 390 ].each { |width| capture("target-#{width}", width) }
      visit workspace_corpus_eval_suite_path(@workspace, @corpus, @suite)
      select "Candidate HTTP agent · v1 · http", from: "Target version"
      click_button "Start fixed run"
      assert_selector "[role=alert]", text: /Confirm disclosure/
      assert_equal 0, EvaluationRun.where(corpus: @corpus).count
      select "Candidate HTTP agent · v1 · http", from: "Target version"
      find("input#disclose").send_keys(:space)
      assert_selector "input#disclose:checked"
      [ 1280, 390 ].each { |width| capture("disclosure-#{width}", width) }
      assert_equal 20, page.evaluate_script("document.querySelector('input[type=checkbox]').getBoundingClientRect().width").round
      click_button "Start fixed run"
      assert_selector "h1", text: /Run/
      run = EvaluationRun.order(:id).last
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(HttpTarget, :perform, ->(*) { raise Net::ReadTimeout }) { EvaluationRunJob.perform_now(run.id) }
      end
      click_link "Refresh run"
      click_link @scenario.current_version.title, match: :first
      assert_text "remote outcome may be unknown"
      assert_text "cost unknown"
      assert_no_button "Review and add regression"
      assert_not_includes page.text, "test-only-token"
      [ 1280, 390 ].each { |width| capture("unknown-result-#{width}", width) }
    end
  end

  private
    def capture(name, width)
      page.current_window.resize_to(width, 1600)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/http-target/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
