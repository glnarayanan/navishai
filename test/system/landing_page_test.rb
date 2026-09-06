require "application_system_test_case"
require "timeout"

class LandingPageTest < ApplicationSystemTestCase
  setup do
    emulate_prefers_reduced_motion("no-preference")
  end

  test "public landing explains the customer workflow without invented claims" do
    visit root_path

    assert_title(/Evidence-backed customer operations/)
    assert_selector "h1", text: /Resolve support cases with proof/
    assert_text "Self-hosted customer operations"
    assert_text "Bring shared email and Intercom into one workspace"
    assert_link "Sign in to your workspace"
    assert_link "See the support workflow"
    assert_text "The customer context behind every answer"
    assert_text "Support history becomes customer context"
    assert_text "Know why an outcome happened"
    assert_text "Run customer operations on infrastructure you control"
    assert_no_text(/SOC 2 certified/i)
    assert_no_text(/trusted by/i)
    assert_selector ".faq-item", text: "does not claim SOC 2, HIPAA, ISO 27001, or any other certification.", visible: :all
    refute_selector "img[alt*='logo' i]"

    assert_selector ".proof-cell", count: 4
    assert_selector ".proof-cell", text: "Conversations become linked cases with Account and Contact context."
    proof_copy = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const node = document.querySelector('.proof-more')
        const style = getComputedStyle(node)
        return {
          visible: node.getBoundingClientRect().height > 0,
          opacity: style.opacity,
          position: style.position
        }
      })()
    JAVASCRIPT
    assert proof_copy["visible"]
    assert_equal "1", proof_copy["opacity"]
    assert_equal "static", proof_copy["position"]

    prominent_copy = page.evaluate_script(<<~JAVASCRIPT)
      [...document.querySelectorAll('.landing-hero, #proof, #how-it-works, #features')]
        .map((node) => node.textContent)
        .join(' ')
    JAVASCRIPT
    refute_match(/control plane|rails\s*\+\s*hotwire|postgresql|runner protocol|scripted adapter|runtime registry|deterministic score|signal weights|tool calls|execution budget/i, prominent_copy)

    section_tops = page.evaluate_script(<<~JAVASCRIPT)
      ['hero', 'proof', 'how-it-works', 'features', 'quote', 'self-host', 'faq', 'get-started']
        .map((id) => document.getElementById(id).offsetTop)
    JAVASCRIPT
    assert_equal section_tops.sort, section_tops

    click_link "See the support workflow", href: "#how-it-works", match: :first
    assert_selector "#how-it-works"

    assert_selector ".workflow-step", text: /Evidence check/

    intercom_faq = find("summary", text: "Does NavishAI replace Intercom?")
    page.scroll_to(intercom_faq, align: :center)
    intercom_faq.click
    assert_text "NavishAI can work beside Intercom and shared email"

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

  test "workflow is one readable sequence on desktop and mobile" do
    visit root_path

    assert_selector "dialog#public-nav-drawer[aria-label='Page navigation']", visible: :all
    assert_no_selector ".readiness-section"
    assert_no_selector ".principles-section"
    assert_no_selector ".principle-stage"
    assert_no_selector ".orbit-stage"

    [ [ 1440, 1000 ], [ 390, 844 ], [ 320, 700 ] ].each do |width, height|
      page.current_window.resize_to(width, height)
      assert_workflow_content
      assert_no_horizontal_overflow
      assert_no_selector "#how-it-works button, #how-it-works [role='tab'], #how-it-works [hidden]", visible: :all
      assert_operator page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('.workflow-copy p')).fontSize)"), :>=, 16
    end
  end

  test "workflow stays readable with JavaScript disabled" do
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
    visit root_path
    assert_workflow_content
    page.current_window.resize_to(390, 844)
    assert_workflow_content
  ensure
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
  end

  test "keyboard can open the workflow from the hero" do
    emulate_prefers_reduced_motion("reduce")
    visit root_path
    link = find(".landing-actions a[href='#how-it-works']")
    link.send_keys(:enter)
    assert_in_delta 100, page.evaluate_script("document.getElementById('how-it-works').getBoundingClientRect().top"), 2
    assert_workflow_content
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

  test "unchanged scroll events share one frame without rewriting the active navigation" do
    visit root_path
    assert_nav_pill_behind_active("Home")

    activity = page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[0]
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, 'landing-header')
      const indicator = document.querySelector('.nav-pill-indicator')
      const originalUpdate = controller.update
      const originalAnimate = indicator.animate
      const activity = { updates: 0, mutations: 0, animations: 0 }
      const observer = new MutationObserver((records) => { activity.mutations += records.length })
      observer.observe(document.querySelector('.site-header-wrap'), { attributes: true, subtree: true })
      controller.update = function() { activity.updates++; originalUpdate.call(this) }
      indicator.animate = function(...args) { activity.animations++; return originalAnimate.apply(this, args) }
      for (let i = 0; i < 20; i++) window.dispatchEvent(new Event('scroll'))
      requestAnimationFrame(() => requestAnimationFrame(() => {
        observer.disconnect()
        controller.update = originalUpdate
        indicator.animate = originalAnimate
        done(activity)
      }))
    JAVASCRIPT

    assert_equal({ "updates" => 1, "mutations" => 0, "animations" => 0 }, activity)
  end

  test "disconnect cancels a pending navigation update" do
    visit root_path
    assert_nav_pill_behind_active("Home")

    updates = page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[0]
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, 'landing-header')
      const originalUpdate = controller.update
      let updates = 0
      controller.update = () => { updates++ }
      window.dispatchEvent(new Event('scroll'))
      controller.disconnect()
      requestAnimationFrame(() => requestAnimationFrame(() => {
        controller.update = originalUpdate
        controller.connect()
        done(updates)
      }))
    JAVASCRIPT

    assert_equal 0, updates
  end

  test "a second jump replaces the pending timeout and disconnect cancels it" do
    visit root_path
    page.current_window.resize_to(1440, 1000)

    result = page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[0]
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "landing-header")
      const features = document.querySelector('.nav-pill a[href="#features"]')
      const home = document.querySelector('.nav-pill a[href="#hero"]')
      const event = (target) => ({ currentTarget: target, preventDefault() {} })
      controller.jump(event(features))
      const firstTimer = controller.jumpTimer
      controller.jump(event(home))
      const replaced = firstTimer != null && firstTimer !== controller.jumpTimer
      controller.disconnect()
      const timerAfterDisconnect = controller.jumpTimer
      window.setTimeout(() => {
        done({ replaced, timerAfterDisconnect, manual: controller.manual })
      }, 600)
    JAVASCRIPT

    assert result.fetch("replaced")
    assert_nil result.fetch("timerAfterDisconnect")
    assert result.fetch("manual")
  end

  test "reduced motion keeps navigation jumps and indicator placement" do
    emulate_prefers_reduced_motion("reduce")
    visit root_path
    page.current_window.resize_to(1440, 1000)

    click_link "Features", href: "#features"
    assert_nav_pill_behind_active("Features")
    assert_in_delta 100, page.evaluate_script("document.getElementById('features').getBoundingClientRect().top"), 2
  end

  test "the hero CTA sizes from its label at 390 pixels" do
    visit root_path
    page.current_window.resize_to(390, 844)

    box = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const link = [...document.querySelectorAll('.landing-actions a')].find((node) => node.textContent.includes('See the support workflow'))
        return { client: link.clientWidth, scroll: link.scrollWidth, width: getComputedStyle(link).width }
      })()
    JAVASCRIPT
    assert_operator box["client"], :>=, box["scroll"], box.inspect
  end

  private
    def assert_workflow_content
      within "#how-it-works" do
        assert_selector "ol.workflow-steps > li", count: 4
        assert_equal [
          "Bring the conversation together",
          "Investigate current evidence",
          "See what needs attention",
          "Edit and send as yourself"
        ], all(".workflow-step h3").map(&:text)
        assert_text "Shared email and Intercom connect the customer, Account, conversation, and case."
        assert_text "The crew uses approved knowledge, scoped memory, Account history, and read-only public sources."
        assert_text "Material claims show whether evidence is supported, stale, conflicting, uncertain, or refused."
        assert_text "A signed-in teammate owns the final wording. NavishAI records the exact message, channel, and actor."
        assert_text "Customer linked"
        assert_text "Rotation runbook · current"
        assert_text "Supported facts stay cited beside the draft"
        assert_text "Edit the wording, confirm the recipient, and send as yourself."
      end
    end

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
          break if metrics && metrics["label"] == label && metrics["leftDelta"] <= 2 && metrics["widthDelta"] <= 2 && metrics["position"] == "absolute"
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
