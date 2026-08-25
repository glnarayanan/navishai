require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  Capybara.default_max_wait_time = 5

  chrome_binary = ENV["CHROME_BIN"] || Dir[File.expand_path("~/.cache/selenium/chrome/linux64/*/chrome")].max

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    options.binary = chrome_binary if chrome_binary
  end

  setup do
    page.current_window.resize_to(1400, 1400)
  end

  def open_workspace_nav
    return unless page.has_button?("Open navigation", wait: 0)

    click_button "Open navigation" unless page.has_selector?("dialog#app-nav-drawer[open]", wait: 0)
  end
end
