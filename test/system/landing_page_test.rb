require "application_system_test_case"

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
end
