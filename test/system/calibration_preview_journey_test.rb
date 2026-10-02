require "application_system_test_case"
require_relative "../test_helpers/calibration_preview_fixture"

class CalibrationPreviewJourneyTest < ApplicationSystemTestCase
  include CalibrationPreviewFixture

  test "expert previews a revised grader sees a missed failure and inspects unchanged original evidence" do
    build_calibration_preview
    sign_in users(:owner)
    visit workspace_corpus_calibration_set_path(@workspace, @corpus, @preview_set)
    assert_no_field "Revised deterministic grader"
    assert_text "Held-out samples never enter this preview"
    capture_states("held-out")
    click_link "Switch to development"
    assert_selector "#fixed-report td", text: "2 true positives"
    select "#{@action_grader.name} v2", from: "Revised deterministic grader"
    find("input[value='Preview on development']").send_keys(:enter)
    assert_selector "#candidate-report h3", text: "Development preview · v2"
    assert_selector "#candidate-report td", text: "1 false negatives"
    assert_selector "#fixed-report td", text: "2 true positives"
    assert_text "Expert labels still belong to the original definitions"
    assert_text "Obtain fresh held-out calibration"
    page.refresh
    assert_selector "#candidate-report td", text: "1 false negatives"
    capture_states("preview")
    within "#candidate-report" do
      assert_link "Sample #{@preview_samples[1].id}", href: workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @preview_set, @preview_samples[1])
      click_link "Sample #{@preview_samples[1].id}"
    end
    assert_selector "h1", text: "Sample #{@preview_samples[1].id}"
    assert_text "Collect expiry evidence v1"
    assert_selector "h2", text: "Machine prediction"
    assert_equal "fail", @preview_samples[1].reload.calibration_prediction.result["decision"]
    assert_equal 1, @preview_samples[1].human_labels.count
    visit workspace_corpus_calibration_set_path(@workspace, @corpus, @preview_set, cohort: "held_out", candidate_version_id: @preview_candidate.id)
    assert_selector "[role=alert]", text: "development samples only"
    assert_no_selector "#candidate-report"
    assert_selector "#fixed-report td", text: "1 true negatives"
    capture_states("blocked-held-out")
    empty = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "New fixed candidate calibration", grader_version_id: @preview_candidate.id)
    visit workspace_corpus_calibration_set_path(@workspace, @corpus, empty, cohort: "development")
    assert_text "No newer deterministic version of this grader"
    assert_text "0 samples · 0 labelled · 0 compared"
    assert_text "Not enough evidence"
    capture_states("empty")
  end

  private
    def capture_states(name)
      [ 1280, 390 ].each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
        assert_no_horizontal_overflow
        assert_no_csp_violations
        next unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

        path = Rails.root.join(".amp/in/artifacts/calibration-preview/#{name}-#{width}.png")
        FileUtils.mkdir_p(path.dirname)
        page.execute_script("window.scrollTo(0, 0)")
        size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
        image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
        File.binwrite(path, Base64.decode64(image.fetch("data")))
      end
    end
end
