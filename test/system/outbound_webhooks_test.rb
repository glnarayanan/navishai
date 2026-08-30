require "application_system_test_case"

class OutboundWebhooksTest < ApplicationSystemTestCase
  test "owner configures a webhook at desktop and mobile widths" do
    sign_in
    click_link "Acme Support"
    click_link "Webhooks"

    assert_selector "h1", text: "Outbound webhooks"
    reveal_setup "Add endpoint"
    fill_in "Name", with: "Ops"
    fill_in "Public HTTPS URL", with: "https://hooks.example.com/navishai"
    fill_in "Credential key", with: "ops"
    click_button "Add endpoint"

    assert_text "Webhook endpoint added."
    assert_selector ".webhook-endpoint", text: "Ops"
    assert_button "Pause"

    page.current_window.resize_to(320, 844)
    assert_operator page.evaluate_script("window.innerWidth"), :<=, 500
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth"), :<=, 0
    endpoint = find(".webhook-endpoint", text: "Ops")
    assert_operator endpoint.find_button("Pause").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    open_workspace_nav
    assert_operator find_link("Webhooks").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    find("body").send_keys(:escape)

    endpoint.find_button("Pause").click
    within find(".webhook-endpoint", text: "Ops") do
      assert_button "Resume"
    end
  end

  private
    def sign_in
      visit new_session_path
      fill_in "Email address", with: users(:owner).email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
    end
end
