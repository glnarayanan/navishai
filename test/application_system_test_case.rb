require "test_helper"
require "fileutils"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  Capybara.default_max_wait_time = 5
  chrome_binary = ENV["CHROME_BIN"] ||
    Dir[File.expand_path("~/.cache/selenium/chrome/linux64/*/chrome")].max ||
    Selenium::WebDriver::SeleniumManager.binary_paths("--browser", "chrome").fetch("browser_path")
  Selenium::WebDriver::Chrome::Service.driver_path = ENV["CHROMEDRIVER_BIN"] if ENV["CHROMEDRIVER_BIN"].present?

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    options.binary = chrome_binary if chrome_binary
    ENV["CHROME_ARGS"].to_s.split.each { |argument| options.add_argument(argument) }
  end

  setup do
    page.current_window.resize_to(1400, 1400)
  end

  def sign_in(user, wait: 6)
    visit new_session_path
    fill_in "Email address", with: user.email_address
    fill_in "Password", with: "password12345"
    click_button "Sign in"
    assert_selector "h1", text: "Choose a workspace", wait:
  end

  def assert_no_horizontal_overflow
    assert_equal page.evaluate_script("document.documentElement.clientWidth"),
      page.evaluate_script("document.documentElement.scrollWidth")
  end

  def assert_no_csp_violations
    assert_empty page.evaluate_script("Array.from(document.querySelectorAll('[style]')).map(element => element.tagName)")
    assert_empty page.evaluate_script("window.__navishaiCspViolations || []")
  end
end
