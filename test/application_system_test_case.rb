require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  Capybara.default_max_wait_time = 5

  chrome_binary = ENV["CHROME_BIN"] || Dir[File.expand_path("~/.cache/selenium/chrome/linux64/*/chrome")].max

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    options.binary = chrome_binary if chrome_binary
  end
end
