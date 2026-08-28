require "test_helper"
require "base64"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  Capybara.default_max_wait_time = 5

  chrome_binary = ENV["CHROME_BIN"] ||
    Dir[File.expand_path("~/.cache/selenium/chrome/linux64/*/chrome")].max ||
    Selenium::WebDriver::SeleniumManager.binary_paths("--browser", "chrome").fetch("browser_path")

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

  def assert_no_csp_violations
    inline_styles = page.evaluate_script(<<~JAVASCRIPT)
      Array.from(document.querySelectorAll('[style]')).map((element) => {
        const className = typeof element.className === 'string' ? element.className : '';
        return `${element.tagName}.${className}[style="${element.getAttribute('style')}"]`;
      })
    JAVASCRIPT
    violations = page.evaluate_script("window.__navishaiCspViolations || []")
    assert_empty inline_styles, inline_styles.join("\n")
    assert_empty violations, violations.join("\n")
  end

  def capture_region(path, from:, through:)
    width = page.evaluate_script("window.innerWidth")
    height = page.evaluate_script("document.documentElement.scrollHeight")
    browser_frame = page.evaluate_script("window.outerHeight - window.innerHeight")
    page.current_window.resize_to(width, height + browser_frame)
    page.execute_script(<<~JAVASCRIPT)
      document.documentElement.style.setProperty('scroll-behavior', 'auto', 'important');
    JAVASCRIPT
    page.evaluate_script("getComputedStyle(document.documentElement).scrollBehavior")
    page.execute_script("window.scrollTo(0, 0)")
    page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[0];
      requestAnimationFrame(() => requestAnimationFrame(done));
    JAVASCRIPT
    scroll_y = page.evaluate_script("window.scrollY")
    raise "capture page did not reach the document top: #{scroll_y}" unless scroll_y.abs < 1

    first = find(from)
    last = find(through)
    clip = page.evaluate_script(<<~JAVASCRIPT, first, last)
      ({
        x: 0,
        y: arguments[0].getBoundingClientRect().top,
        width: window.innerWidth,
        height: arguments[1].getBoundingClientRect().bottom - arguments[0].getBoundingClientRect().top,
        scale: 1
      })
    JAVASCRIPT
    raise "capture region has invalid bounds: #{clip.inspect}" unless clip.fetch("y") >= 0 && clip.fetch("height").positive?

    screenshot = page.driver.browser.execute_cdp(
      "Page.captureScreenshot", format: "png", captureBeyondViewport: true, clip:
    )
    File.binwrite(path, Base64.strict_decode64(screenshot.fetch("data")))
  ensure
    page.execute_script("document.documentElement.style.removeProperty('scroll-behavior')")
  end

  def capture_viewport(path, element, height:)
    width = page.evaluate_script("window.innerWidth")
    browser_frame = page.evaluate_script("window.outerHeight - window.innerHeight")
    page.current_window.resize_to(width, height + browser_frame)
    page.execute_script("document.documentElement.style.setProperty('scroll-behavior', 'auto', 'important')")
    page.evaluate_script("getComputedStyle(document.documentElement).scrollBehavior")
    page.execute_script("arguments[0].scrollIntoView({ block: 'start' })", element)
    page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[0];
      requestAnimationFrame(() => requestAnimationFrame(done));
    JAVASCRIPT
    save_screenshot(path)
  ensure
    page.execute_script("document.documentElement.style.removeProperty('scroll-behavior')")
  end
end
