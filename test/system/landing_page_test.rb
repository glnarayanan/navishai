require "application_system_test_case"
require "timeout"

class LandingPageTest < ApplicationSystemTestCase
  test "public landing explains the self-hosted product without invented claims" do
    visit root_path

    assert_title(/NavishAI/)
    assert_selector "h1", text: /Specialist AI crews/
    assert_text "Open source and self-hosted"
    assert_text "A signed-in human still reviews every customer message"
    assert_link "Sign in"
    assert_link "See how it works"
    assert_no_text(/SOC 2 certified/i)
    assert_no_text(/trusted by/i)
    assert_text "does not claim SOC 2, HIPAA, ISO 27001, or any other certification."
    refute_selector "img[alt*='logo' i]"

    click_link "See how it works", href: "#how-it-works", match: :first
    assert_selector "#how-it-works"

    click_button "Review the draft", match: :first
    assert_selector ".feature-panel:not([hidden])", text: /Policy review/

    find("summary", text: "Does this replace Intercom on day one?").click
    assert_text "Intercom remains authoritative"

    page.current_window.resize_to(390, 844)
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth"), :<=, 0
    click_button "Open menu"
    assert_selector "dialog[open]"
    assert_link "How it works", visible: true
    assert_link "Sign in", visible: true
    find("body").send_keys(:escape)
    assert_no_selector "dialog[open]"
    assert_includes page.evaluate_script("getComputedStyle(document.body).fontFamily"), "Geist"
  end

  test "workflow tabs, pause control, and named navigation follow ARIA patterns" do
    visit root_path
    page.current_window.resize_to(1440, 1000)

    assert_selector "dialog#public-nav-drawer[aria-label='Page navigation']", visible: :all
    assert_no_selector "#readiness [role='tablist']"
    assert_selector "#readiness [role='group'][aria-label='Product path'] button[aria-pressed='true']", text: "Support"

    click_button "Customer Success"
    assert_selector "#readiness button[aria-pressed='true']", text: "Customer Success"
    assert_text "Deterministic account-health signals"

    assert_button "Pause slideshow"
    click_button "Pause slideshow"
    assert_button "Play slideshow"
    assert_selector ".feature-pause[aria-pressed='true']"

    first_tab = find("#workflow-tab-0")
    first_tab.click
    first_tab.send_keys(:arrow_right)
    assert_equal "workflow-tab-1", page.evaluate_script("document.activeElement.id")
    assert_selector "#workflow-panel-1:not([hidden])[role='tabpanel']"
    find("#workflow-tab-1").send_keys(:end)
    assert_equal "workflow-tab-3", page.evaluate_script("document.activeElement.id")
    find("#workflow-tab-3").send_keys(:home)
    assert_equal "workflow-tab-0", page.evaluate_script("document.activeElement.id")

    inner = page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('.orbit-ring-inner')).width)")
    outer = page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('.orbit-ring-outer')).width)")
    dot_left = page.evaluate_script("getComputedStyle(document.querySelector('.globe-dot-1')).left")
    assert_operator inner, :>=, 180
    assert_operator outer, :>=, 400
    refute_equal "auto", dot_left
    refute_equal "0px", dot_left
  end

  test "reduced motion keeps the slideshow paused until Play is pressed" do
    emulate_prefers_reduced_motion("reduce")
    visit root_path
    page.current_window.resize_to(1440, 1000)

    assert_button "Play slideshow"
    assert_selector ".feature-pause[aria-pressed='true']"
    assert_selector "#workflow-tab-0[aria-selected='true']"
    assert_selector "#workflow-panel-0:not([hidden])"

    click_button "Play slideshow"
    assert_button "Pause slideshow"
    assert_selector ".feature-pause[aria-pressed='false']"

    assert_selector "#workflow-tab-1[aria-selected='true']", wait: 6
    assert_selector "#workflow-panel-1:not([hidden])"
    assert_no_selector "#workflow-tab-0[aria-selected='true']"
  end

  test "principles use a 750px vertical column stage and a readable reduced-motion grid" do
    emulate_prefers_reduced_motion("no-preference")
    visit root_path
    page.current_window.resize_to(1440, 1000)

    geometry = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const stage = document.querySelector('.principle-stage')
        const columns = [...document.querySelectorAll('.principle-column')]
        const visible = columns.filter((column) => getComputedStyle(column).display !== 'none')
        const tracks = [...document.querySelectorAll('.principle-column-track')]
        const staticCopy = document.querySelector('.principle-static')
        const horizontal = tracks.some((track) => {
          const transform = getComputedStyle(track).animationName || ''
          return transform.includes('marquee') && !transform.includes('vertical')
        })
        return {
          height: Math.round(stage.getBoundingClientRect().height),
          overflow: getComputedStyle(stage).overflow,
          overflowX: getComputedStyle(stage).overflowX,
          overflowY: getComputedStyle(stage).overflowY,
          columns: visible.length,
          stageHidden: stage.getAttribute('aria-hidden'),
          staticHidden: staticCopy.getAttribute('aria-hidden'),
          staticClip: getComputedStyle(staticCopy).clip,
          staticPosition: getComputedStyle(staticCopy).position,
          horizontal
        }
      })()
    JAVASCRIPT
    assert_in_delta 750, geometry["height"], 1
    assert_equal "hidden", geometry["overflow"]
    assert_equal 3, geometry["columns"]
    assert_equal "true", geometry["stageHidden"]
    assert_nil geometry["staticHidden"]
    assert geometry["staticPosition"] == "absolute"
    refute geometry["horizontal"]

    emulate_prefers_reduced_motion("reduce")
    visit root_path
    page.current_window.resize_to(1440, 1000)

    reduced = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const stage = document.querySelector('.principle-stage')
        const staticCopy = document.querySelector('.principle-static')
        const first = staticCopy.querySelector('.principle-card')
        return {
          stageDisplay: getComputedStyle(stage).display,
          staticDisplay: getComputedStyle(staticCopy).display,
          staticPosition: getComputedStyle(staticCopy).position,
          staticClip: getComputedStyle(staticCopy).clip,
          staticHidden: staticCopy.getAttribute('aria-hidden'),
          staticWidth: Math.round(staticCopy.getBoundingClientRect().width),
          cardVisible: first.getBoundingClientRect().height > 0,
          cardAriaHidden: first.closest('[aria-hidden="true"]') !== null,
          columns: [...new Set([...staticCopy.querySelectorAll('.principle-card')].map((card) => Math.round(card.getBoundingClientRect().left)))].length,
          overflow: Math.max(0, staticCopy.scrollWidth - staticCopy.clientWidth)
        }
      })()
    JAVASCRIPT
    assert_equal "none", reduced["stageDisplay"]
    assert_equal "grid", reduced["staticDisplay"]
    assert_equal "static", reduced["staticPosition"]
    refute_match(/rect\(0/, reduced["staticClip"].to_s)
    assert_nil reduced["staticHidden"]
    assert reduced["cardVisible"]
    refute reduced["cardAriaHidden"]
    assert_equal 3, reduced["columns"]
    assert_operator reduced["staticWidth"], :>=, 1000
    assert_operator reduced["overflow"], :<=, 0
    assert_text "A human reviews the current draft and presses Send"
  end

  test "the desktop nav pill sits behind the active link at rest and after a jump" do
    visit root_path
    page.current_window.resize_to(1440, 1000)
    assert_nav_pill_behind_active("Home")

    click_link "Features", href: "#features"
    assert_nav_pill_behind_active("Features")

    page.current_window.resize_to(1024, 900)
    click_link "Home", href: "#hero"
    assert_nav_pill_behind_active("Home")
  end

  test "the hero CTA sizes from its label at 390 pixels" do
    visit root_path
    page.current_window.resize_to(390, 844)

    box = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const link = [...document.querySelectorAll('.landing-actions a')].find((node) => node.textContent.includes('See how it works'))
        return { client: link.clientWidth, scroll: link.scrollWidth, width: getComputedStyle(link).width }
      })()
    JAVASCRIPT
    assert_operator box["client"], :>=, box["scroll"], box.inspect
  end

  private
    def emulate_prefers_reduced_motion(value)
      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia",
        features: [ { name: "prefers-reduced-motion", value: value } ]
      )
    end

    def teardown
      emulate_prefers_reduced_motion("no-preference")
    rescue StandardError
      nil
    ensure
      super
    end

    def assert_nav_pill_behind_active(label)
      metrics = nil
      Timeout.timeout(Capybara.default_max_wait_time) do
        loop do
          metrics = page.evaluate_script(<<~JAVASCRIPT)
            (() => {
              const indicator = document.querySelector('.nav-pill-indicator')
              const active = document.querySelector('.nav-pill a.is-active') || document.querySelector('.nav-pill a[aria-current="true"]')
              if (!indicator || !active) return null
              const item = active.parentElement
              const indicatorRect = indicator.getBoundingClientRect()
              const itemRect = item.getBoundingClientRect()
              return {
                label: active.textContent.trim(),
                position: getComputedStyle(indicator).position,
                leftDelta: Math.abs(indicatorRect.left - itemRect.left),
                widthDelta: Math.abs(indicatorRect.width - itemRect.width),
                behind: parseInt(getComputedStyle(indicator).zIndex, 10) < parseInt(getComputedStyle(item).zIndex, 10)
              }
            })()
          JAVASCRIPT
          break if metrics && metrics["label"] == label && metrics["leftDelta"] <= 2 && metrics["position"] == "absolute"
          sleep 0.05
        end
      end
      assert_equal label, metrics["label"]
      assert_equal "absolute", metrics["position"]
      assert_operator metrics["leftDelta"], :<=, 2, metrics.inspect
      assert_operator metrics["widthDelta"], :<=, 2, metrics.inspect
      assert metrics["behind"], metrics.inspect
    end
end
