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
end
