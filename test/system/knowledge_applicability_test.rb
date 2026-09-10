require "application_system_test_case"

class KnowledgeApplicabilityTest < ApplicationSystemTestCase
  test "admin configures product applicability on desktop and mobile" do
    workspace = workspaces(:acme_support)
    source = KnowledgeIngestion.create!(workspace:, membership: memberships(:owner_support),
      source_kind: "manual", title: "Recovery guidance", content: "Recovery instructions.")
    sign_in(users(:owner))
    visit workspace_products_path(workspace)
    within "section[aria-labelledby='add-product-title']" do
      fill_in "Product name", with: "Billing"
      click_button "Add product"
    end
    assert_text "Product added."
    visit workspace_knowledge_source_path(workspace, source)
    find("summary", text: "Edit applicability").click
    uncheck "All products"
    check "Billing"
    click_button "Save applicability"
    assert_text "Knowledge applicability saved."
    assert_text "This source has a manual mapping."

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 844, deviceScaleFactor: 1, mobile: false)
    find("summary", text: "Edit applicability").click
    assert_equal 320, page.evaluate_script("window.innerWidth")
    assert_no_csp_violations
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_selector "label[for='applicability_source_#{source.id}_all_products']", text: "All products"
    find_button("Save applicability").send_keys(:tab)
    assert_selector "button:focus", text: "Reset to defaults"
    save_screenshot Rails.root.join("tmp/knowledge-applicability-mobile.png")
    click_button "Reset to defaults"
    assert_text "Knowledge applicability reset to defaults."
    assert_text "This source inherits its connection defaults"
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1440, 1000)
    save_screenshot Rails.root.join("tmp/knowledge-applicability-desktop.png")
  end
  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
