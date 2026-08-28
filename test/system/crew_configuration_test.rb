require "application_system_test_case"

class CrewConfigurationSystemTest < ApplicationSystemTestCase
  test "an Owner reviews and versions bounded crew policy on desktop and mobile" do
    workspace = workspaces(:acme_support)
    CrewConfiguration.install_defaults!(workspace: workspace)
    ResolutionContractConfiguration.install_defaults!(workspace: workspace)
    investigator = workspace.agent_profiles.find_by!(role_key: "support_investigator")
    sign_in(users(:owner))
    visit workspace_crew_templates_path(workspace)

    assert_text "Specialist crews"
    assert_text "Human send stays separate"
    assert_text "Resolution contracts"
    support_contract = workspace.resolution_contract_families.find_by!(family_key: "support_resolution")
    within "#contract-#{support_contract.id}" do
      find("summary").click
      assert_text "Resolution changes require a retained-fact preview and named canary."
      assert_link "Open Governed policy"
      assert_no_field "Execution budget threshold"
    end

    within "#profile-#{investigator.id}" do
      find("summary").click
      fill_in "Role instructions", with: "Investigate current evidence, cite sources, and state uncertainty."
      uncheck "Search the public web"
      click_button "Save new policy version"
    end

    assert_text "Investigator policy updated."
    within "#profile-#{investigator.id}" do
      find("summary").click
      assert_text "Version 2"
      within ".agent-tool-list" do
        assert_no_text "Search the public web"
      end
      assert_unchecked_field "Search the public web"
      select "Thorough", from: "Primary runtime profile"
      click_button "Save new policy version"
    end
    assert_text "Routing, fallback, review, and execution budgets require Governed policy preview"
    assert_equal 2, investigator.reload.current_version.version_number

    page.current_window.resize_to(375, 844)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    open_workspace_nav
    crews_link = find_link("Crews", match: :first)
    assert_operator crews_link.rect.width, :>=, 48
    assert_operator crews_link.rect.height, :>=, 48
    find("body").send_keys(:escape)
    assert_operator find("#profile-#{investigator.id} summary").rect.height, :>=, 48
    assert_operator find("#contract-#{support_contract.id} summary").rect.height, :>=, 48
    contract_card = find("#contract-#{support_contract.id}")
    contract_card.find("summary").click unless page.evaluate_script("arguments[0].open", contract_card)
    within contract_card do
      assert_operator find_link("Open Governed policy").rect.height, :>=, 44
    end
    assert_no_horizontal_overflow
    save_screenshot Rails.root.join(".amp/in/artifacts/crew-configuration-mobile.png") if ENV["CAPTURE_CREWS"]
    if ENV["CAPTURE_CREWS"]
      contract = find("#contract-#{support_contract.id}")
      contract.find("summary").click
      governed_link = contract.find_link("Open Governed policy")
      page.execute_script("arguments[0].scrollIntoView({block: 'center'})", governed_link)
      save_screenshot Rails.root.join(".amp/in/artifacts/crew-configuration-mobile-editor.png")
    end

    page.current_window.resize_to(1440, 1000)
    page.execute_script("window.scrollTo(0, 0)")
    save_screenshot Rails.root.join(".amp/in/artifacts/crew-configuration-desktop.png") if ENV["CAPTURE_CREWS"]
  end

  private
    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_on "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end
end
