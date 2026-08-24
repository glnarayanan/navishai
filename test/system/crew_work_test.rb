require "application_system_test_case"

class CrewWorkSystemTest < ApplicationSystemTestCase
  test "an Owner plans, records, reviews, and completes specialist work on desktop and mobile" do
    workspace = workspaces(:acme_support)
    CrewConfiguration.install_defaults!(workspace: workspace)
    support_case = create_support_case
    sign_in(users(:owner))
    visit workspace_support_case_path(workspace, support_case)

    within ".case-crew-summary" do
      assert_text "No specialist work has been planned"
      click_on "Open"
    end
    assert_text "Crew work"
    fill_in "Task title", with: "Investigate sign-in failure"
    fill_in "Input and scope", with: "Use the current case conversation and approved knowledge sources. Do not infer account facts."
    fill_in "Expected output", with: "Find the cause, cite the case record, and state every material uncertainty."
    select "Investigator", from: "Specialist"
    click_button "Create task"

    assert_text "Crew task created."
    assert_text "Ready"
    click_button "Start task"
    assert_text "In progress"

    comment_form = find("input[value='comment']", visible: :all).ancestor("form")
    within comment_form do
      fill_in "Comment", with: "The current case record points to an expired identity-provider session."
      click_button "Add comment"
    end
    assert_text "The current case record points to an expired identity-provider session."

    find("summary", text: "Handoff or outcome").click
    review_form = find("input[value='request_review']", visible: :all).ancestor("form")
    within review_form do
      fill_in "What needs review", with: "Check the evidence link and the stated cause."
      click_button "Request review"
    end
    assert_text "Review requested"

    review_decision_form = find("input[value='review']", visible: :all).ancestor("form")
    within review_decision_form do
      select "Approve outcome", from: "Decision"
      fill_in "Review record", with: "The result stays within the cited case facts."
      click_button "Record decision"
    end
    assert_text "Completed"
    assert_text "Decision: Approved"
    assert_selector ".crew-event-list li", count: 5
    visit page.current_path

    page.current_window.resize_to(320, 844)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_operator find_link("Back to crew work").rect.height, :>=, 48
    assert_operator find(".crew-task-list-item").rect.height, :>=, 48
    save_screenshot Rails.root.join(".amp/in/artifacts/crew-work-mobile.png") if ENV["CAPTURE_CREW_WORK"]

    page.current_window.resize_to(1440, 1000)
    page.execute_script("window.scrollTo(0, 0)")
    save_screenshot Rails.root.join(".amp/in/artifacts/crew-work-desktop.png") if ENV["CAPTURE_CREW_WORK"]
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
