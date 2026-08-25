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

  test "the workspace theme menu stays on screen at 1024 by 900" do
    visit new_session_path
    fill_in "Email address", with: users(:owner).email_address
    fill_in "Password", with: "password12345"
    click_button "Sign in"
    click_link "Acme Support"

    page.current_window.resize_to(1024, 900)
    open_workspace_nav
    within "dialog#app-nav-drawer" do
      find("summary.theme-toggle").click
      %w[System Light Dark].each do |label|
        button = find_button(label)
        box = button.evaluate_script("(() => { const r = this.getBoundingClientRect(); return [r.top, r.bottom, r.left, r.right]; })()")
        assert_operator box[0], :>=, 0, "#{label} top #{box[0]}"
        assert_operator box[1], :<=, 900, "#{label} bottom #{box[1]}"
        assert_operator box[2], :>=, 0, "#{label} left #{box[2]}"
        assert_operator box[3], :<=, 1024, "#{label} right #{box[3]}"
      end
      click_button "Dark"
    end

    assert_equal "dark", page.evaluate_script("document.documentElement.getAttribute('data-theme')")
  end
end
