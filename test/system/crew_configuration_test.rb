require "application_system_test_case"

class CrewConfigurationSystemTest < ApplicationSystemTestCase
  test "an Owner reviews and versions specialist settings on desktop and mobile" do
    workspace = workspaces(:acme_support)
    CrewConfiguration.install_defaults!(workspace: workspace)
    ResolutionContractConfiguration.install_defaults!(workspace: workspace)
    investigator = workspace.agent_profiles.find_by!(role_key: "support_investigator")
    sign_in(users(:owner))
    visit workspace_crew_templates_path(workspace)

    assert_text "Specialist crews"
    assert_text "Human send stays separate"
    assert_text "Result requirements"
    support_contract = workspace.resolution_contract_families.find_by!(family_key: "support_resolution")
    within "#contract-#{support_contract.id}" do
      find("summary").click
      assert_text "Test requirement changes on selected cases or accounts before publishing them."
      assert_link "Review policy changes"
      assert_no_field "Execution budget threshold"
    end

    within "#profile-#{investigator.id}" do
      find("summary").click
      fill_in "Role instructions", with: "Investigate current evidence, cite sources, and state uncertainty."
      uncheck "Search the public web"
      click_button "Save changes"
    end

    assert_text "Investigator policy updated."
    within "#profile-#{investigator.id}" do
      find("summary").click
      assert_text "Investigate current evidence, cite sources, and state uncertainty."
      within ".agent-tool-list" do
        assert_no_text "Search the public web"
      end
      assert_unchecked_field "Search the public web"
      assert_no_field "Primary processing profile"
      assert_no_field "Maximum steps"
      assert_no_field "Maximum tool calls"
    end
    assert_equal 2, investigator.reload.current_version.version_number
    within "#profile-#{investigator.id}" do
      assert_operator find(".agent-tool-list li", match: :first).rect.height, :<=, 36
      assert_operator find_button("Save changes").rect.width, :<, 260
    end

    page.current_window.resize_to(375, 844)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    open_workspace_nav
    crews_link = find_link("Crew setup", match: :first)
    assert_operator crews_link.rect.width, :>=, 48
    assert_operator crews_link.rect.height, :>=, 48
    find("body").send_keys(:escape)
    assert_operator find("#profile-#{investigator.id} > summary").rect.height, :>=, 48
    assert_operator find("#contract-#{support_contract.id} summary").rect.height, :>=, 48
    contract_card = find("#contract-#{support_contract.id}")
    contract_card.find("summary").click unless page.evaluate_script("arguments[0].open", contract_card)
    within contract_card do
      assert_operator find_link("Review policy changes").rect.height, :>=, 44
    end
    assert_no_horizontal_overflow
    save_screenshot Rails.root.join(".amp/in/artifacts/crew-configuration-mobile.png") if ENV["CAPTURE_CREWS"]
    if ENV["CAPTURE_CREWS"]
      contract = find("#contract-#{support_contract.id}")
      contract.find("summary").click
      governed_link = contract.find_link("Review policy changes")
      page.execute_script("arguments[0].scrollIntoView({block: 'center'})", governed_link)
      save_screenshot Rails.root.join(".amp/in/artifacts/crew-configuration-mobile-editor.png")
    end

    page.current_window.resize_to(1440, 1000)
    page.execute_script("window.scrollTo(0, 0)")
    save_screenshot Rails.root.join(".amp/in/artifacts/crew-configuration-desktop.png") if ENV["CAPTURE_CREWS"]
  end
end
