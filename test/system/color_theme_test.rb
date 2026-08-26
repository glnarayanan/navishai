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

  test "theme radios use wrapped arrows and roving tabindex" do
    visit root_path
    page.current_window.resize_to(1440, 1000)

    find("summary.theme-toggle").click
    group = find(".theme-menu[role='radiogroup']", match: :first)
    system_option = group.find_button("System")
    light_option = group.find_button("Light")
    dark_option = group.find_button("Dark")

    assert_equal "true", system_option["aria-checked"]
    assert_equal "0", system_option[:tabindex]
    assert_equal "-1", light_option[:tabindex]
    assert_equal "-1", dark_option[:tabindex]

    system_option.send_keys(:arrow_down)
    assert_equal "Light", page.evaluate_script("document.activeElement.textContent.trim()")
    assert_equal "true", group.find_button("Light")["aria-checked"]
    assert_equal "false", group.find_button("System")["aria-checked"]
    assert_equal "0", group.find_button("Light")[:tabindex]
    assert_equal "-1", group.find_button("System")[:tabindex]
    assert_selector "details.theme-control[open]"

    group.find_button("Light").send_keys(:arrow_down)
    assert_equal "Dark", page.evaluate_script("document.activeElement.textContent.trim()")
    group.find_button("Dark").send_keys(:arrow_down)
    assert_equal "System", page.evaluate_script("document.activeElement.textContent.trim()")
    assert_equal "true", group.find_button("System")["aria-checked"]
    assert_selector "details.theme-control[open]"
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
