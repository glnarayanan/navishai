require "application_system_test_case"
require_relative "../test_helpers/model_failure_matching_test_helper"

class ModelFailureMatchingJourneyTest < ApplicationSystemTestCase
  include ModelFailureMatchingTestHelper

  test "owner previews repairs confirms once and inspects advisory results at desktop and mobile widths" do
    build_model_matching_fixture
    sign_in users(:owner)
    visit source_path
    find("summary", text: "Optional model failure matching").send_keys(:enter)
    click_link "Preview optional model matching"
    assert_text "3 eligible versions"
    assert_text "No model attempt retained for this trace."
    assert_no_button "Request matching suggestions once"
    field = "Matching endpoint, model and fixed settings (JSON)"
    fill_in field, with: "{broken"
    click_button "Preview exact matching request"
    assert_selector "[role=alert]", text: "Configuration is not valid JSON"
    assert_field field, with: "{broken"
    [ 1280, 390 ].each { |width| capture("repair-#{width}", width, selector: "#matching-error-#{@item.id}") }

    calls = []
    with_matching_response(calls:) do
      fill_in field, with: matching_configuration.to_json
      click_button "Preview exact matching request"
      assert_selector "h4#matching-disclosure-#{@item.id}", text: "Confirm this exact matching disclosure"
      assert_text HTTP_ENDPOINT
      assert_unchecked_field "I reviewed every disclosed field and approve sending this exact trace and candidate set to this endpoint for model failure matching."
      within "section[aria-labelledby='matching-disclosure-#{@item.id}']" do
        find("summary", text: "Complete request JSON").send_keys(:enter)
        assert_text "Request quota exhausted; retry after cooldown."
        assert_text "Request quota is NOT exhausted"
        assert_text "untrusted data"
        assert_no_text "PRIVATE_HIDDEN_FACT"
        assert_no_text "PRIVATE_REVIEW_NOTE"
        [ 1280, 390, 320 ].each { |width| capture("disclosure-#{width}", width, selector: "section[aria-labelledby='matching-disclosure-#{@item.id}']") }
        find("summary", text: "Complete request JSON").send_keys(:enter)
      end
      [ 1280, 390 ].each { |width| capture("confirmation-#{width}", width, selector: "section[aria-labelledby='matching-disclosure-#{@item.id}']") }
      fill_in "Type the exact endpoint to confirm the destination", with: HTTP_ENDPOINT
      check "I reviewed every disclosed field and approve sending this exact trace and candidate set to this endpoint for model failure matching."
      click_button "Request matching suggestions once"
      assert_text "Matching attempt retained"
      request = ModelFailureMatching.where(corpus: @corpus).sole
      assert_selector "h4", text: "Matching attempt #{request.id} · queued"
      assert_empty calls
      [ 1280, 390 ].each { |width| capture("queued-#{width}", width, selector: "section[aria-labelledby='matching-attempt-#{request.id}']") }
      2.times { ModelFailureMatchingJob.perform_now(request.id) }
      click_link "Refresh matching state"
      assert_selector "h3", text: "Model suggestions — not expert decisions"
      assert_selector "h4", text: "Match suggestion · version ID #{@paraphrase.id}"
      assert_selector "h4", text: "No-match suggestion · version ID #{@negated.id}"
      assert_selector "h4", text: "Uncertain suggestion · version ID #{@version.id}"
      [ 1280, 390, 320 ].each { |width| capture("result-#{width}", width, selector: "#model-matching-#{@item.id} h3") }
      [ 1280, 390 ].each { |width| capture("uncertainty-#{width}", width, selector: "#model-matching-#{@item.id} article:last-of-type") }
      assert_equal 1, calls.size
      assert_empty TraceScenarioDecision.where(corpus: @corpus)
      assert_empty HumanLabel.where(corpus: @corpus)
      assert_empty RegressionCase.where(corpus: @corpus)
    end
  end

  test "oversized candidate set offers recovery and no disclosure or sampled form" do
    build_model_matching_fixture
    18.times { |i| matching_version(title: "Extra eligible #{i}") }
    sign_in users(:owner)
    visit source_path(model_matching_item_id: @item.id)
    assert_selector "#model-matching-#{@item.id} [role=alert]", text: "no candidates were sampled or loaded"
    assert_link "Inspect corpus scenarios"
    assert_no_button "Preview exact matching request"
    assert_no_button "Request matching suggestions once"
    [ 1280, 390 ].each { |width| capture("bounded-refusal-#{width}", width, selector: "#model-matching-#{@item.id}") }
  end

  private
    def source_path(**params)
      workspace_corpus_source_path(@workspace, @corpus, @item.source_snapshot.source, **params)
    end

    def capture(name, width, selector:)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      page.driver.browser.execute_async_script("const done = arguments[arguments.length - 1]; requestAnimationFrame(() => requestAnimationFrame(done));")
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/model-failure-matching/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("document.querySelector(#{selector.to_json}).scrollIntoView({block: 'start'})")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: false)
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
