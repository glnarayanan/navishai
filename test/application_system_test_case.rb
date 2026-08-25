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

  def reveal_setup(summary_text)
    summary = find("summary", text: summary_text, match: :first)
    page.execute_script("arguments[0].open = true", summary.ancestor("details"))
  end

  def assert_no_horizontal_overflow
    client_width = page.evaluate_script("document.documentElement.clientWidth")
    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    offenders = page.evaluate_script(<<~JAVASCRIPT)
      Array.from(document.querySelectorAll('body *')).filter((element) => {
        const rect = element.getBoundingClientRect();
        return rect.right > document.documentElement.clientWidth + 1 || rect.left < -1;
      }).slice(0, 12).map((element) => {
        const className = typeof element.className === 'string' ? element.className : '';
        return `${element.tagName}.${className}:${Math.round(element.getBoundingClientRect().left)}-${Math.round(element.getBoundingClientRect().right)}`;
      })
    JAVASCRIPT
    assert_equal client_width, scroll_width, offenders.join(", ")
  end
end
