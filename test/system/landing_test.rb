require "application_system_test_case"

class LandingTest < ApplicationSystemTestCase
  test "public page retains its content at desktop tablet and narrow widths in both themes" do
    [ 1280, 768, 390, 320 ].each do |width|
      viewport(width)
      visit root_path
      assert_selector "h1", text: "Test your AI's SSO handoffs, API fixes and billing rules"
      assert_selector ".landing-workflow li", count: 6
      assert_selector ".landing-specimen figcaption", text: "not customer data or a run"
      assert_selector "main a.button-primary", text: "Sign in to the lab"
      assert_equal "Geist, system-ui, sans-serif", page.evaluate_script("getComputedStyle(document.documentElement).fontFamily")
      assert_operator page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('.landing h1')).fontSize)"), :>=, 36

      %w[dark light].each do |theme|
        find(".theme-toggle").click
        find("[data-theme-value=#{theme}]").click
        assert_selector "html[data-theme=#{theme}]"
        assert_equal theme == "dark", page.evaluate_script("document.documentElement.classList.contains('dark')")
        assert_no_horizontal_overflow
        assert_no_csp_violations
        capture("public-#{theme}-#{width}") if [ 1280, 390 ].include?(width)
      end
    end
  end

  test "anchors disclosures keyboard focus and real sign-in remain usable" do
    viewport(390)
    visit root_path
    page.driver.browser.action.send_keys(:tab).perform
    assert_equal "Skip to content", page.evaluate_script("document.activeElement.textContent")
    page.driver.browser.action.send_keys(:enter).perform
    assert_selector "#main-content:focus"

    click_link "Data boundaries"
    assert_current_path root_path
    assert_selector "#privacy:target"
    assert_operator page.evaluate_script("document.querySelector('#privacy').getBoundingClientRect().top"), :>=, 0
    variant = find("#example .landing-disclosure summary")
    variant.send_keys(:enter)
    assert_selector "#example details[open]", text: "exact before/after values"

    faq = find(".landing-questions summary", text: "Does a passing suite mean the agent is safe to ship?")
    faq.send_keys(:enter)
    assert_selector ".landing-questions details[open]", text: "unknown cost stays unknown"
    assert_no_horizontal_overflow
    assert_no_csp_violations
    capture("public-expanded-390")
    click_link "Back to top"
    click_link "Sign in to the lab", match: :first
    assert_current_path new_session_path
    assert_selector "h1", text: "Sign in"
  end

  test "signed-in root opens workspaces and sign out returns to public landing" do
    sign_in users(:owner)
    [ 1280, 390, 320 ].each do |width|
      viewport(width)
      visit root_path
      assert_current_path workspaces_path
      assert_selector "h1", text: "Choose a workspace"
      assert_no_selector "main.landing"
      %w[dark light].each do |theme|
        find(".theme-toggle").click
        find("[data-theme-value=#{theme}]").click
        assert_selector "html[data-theme=#{theme}]"
        assert_no_horizontal_overflow
        assert_no_csp_violations
        capture("signed-in-#{theme}-#{width}") if [ 1280, 390 ].include?(width)
      end
    end
    find(".lab-navigation summary").click
    click_button "Sign out"
    visit root_path
    assert_selector "main.landing"
  end

  private
    def viewport(width)
      page.current_window.resize_to(width, 900)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: 900, deviceScaleFactor: 2, mobile: false)
    end

    def capture(name)
      return unless ENV["CAPTURE_LANDING_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/landing/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      save_screenshot(path)
    end
end
