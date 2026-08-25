require "application_system_test_case"

class ColorThemeTest < ApplicationSystemTestCase
  test "people can choose a color theme and keep it" do
    visit root_path

    find("summary.theme-toggle").click
    click_button "Dark"

    assert page.evaluate_script("document.documentElement.classList.contains('dark')")
    assert_equal "dark", page.evaluate_script("document.documentElement.getAttribute('data-theme')")

    visit new_session_path

    assert page.evaluate_script("document.documentElement.classList.contains('dark')")
    assert_selector ".auth-panel"
    assert_text "Dark"

    find("summary.theme-toggle").click
    click_button "Light"

    assert_not page.evaluate_script("document.documentElement.classList.contains('dark')")
    assert_equal "light", page.evaluate_script("document.documentElement.getAttribute('data-theme')")
  end
end
