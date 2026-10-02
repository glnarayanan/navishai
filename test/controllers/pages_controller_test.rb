require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "public landing explains the evaluation loop with real routes and labelled examples" do
    assert_no_difference [ "AuditEvent.count", "Corpus.count", "Scenario.count", "EvaluationRun.count" ] do
      get root_path
    end

    assert_response :success
    assert_select "title", text: "Company-specific AI support evaluation — NavishAI"
    assert_select "meta[name=description][content*=calibrated]"
    assert_select "main", count: 1
    assert_select "h1", count: 1
    assert_select "main.landing a.button-primary[href=?]", new_session_path, text: "Sign in to the lab"
    assert_select "main.landing a[href=?]", new_setup_path, count: 0
    assert_select "nav[aria-label='On this page'] a" do |links|
      assert_equal %w[#workflow #example #privacy], links.map { |link| link["href"] }
    end
    %w[workflow example privacy].each { |id| assert_select "##{id}", count: 1 }
    assert_select ".landing-workflow h3" do |headings|
      assert_equal [ "Build a source-backed corpus", "Find cases worth testing",
        "Let experts define good support", "Compile the behaviour into checks",
        "Calibrate against human judgment", "Inspect failures. Keep regressions." ], headings.map(&:text)
    end
    assert_select "figure figcaption", text: /Illustrative SSO case.*not customer data or a run/
    assert_select "#privacy dd", text: /do not remove all PII/
    assert_select "#privacy dd", text: /cannot recall data already sent/
    assert_select ".landing-disclosure", count: 6
    assert_select ".landing-disclosure p", text: /not live vendor connections/
    assert_select ".landing-disclosure p", text: /does not establish coverage.*grader accuracy/
    assert_select "[style], iframe, main img, main form", count: 0
    assert_not_includes response.body, "The lab is being rebuilt"
    assert_not_includes response.body, "Model judges are next"
  end

  test "signed-in root keeps the real workspace redirect without rendering marketing" do
    sign_in_as users(:owner)

    get root_path

    assert_redirected_to workspaces_path
    follow_redirect!
    assert_response :success
    assert_select "h1", text: "Choose a workspace"
    assert_select "main.landing", count: 0
  end

  test "an expired session sees the public landing rather than workspace data" do
    sign_in_as users(:owner)
    Current.session.update!(expires_at: 1.minute.ago)

    get root_path

    assert_response :success
    assert_select "main.landing"
    assert_select "main a[href=?]", workspaces_path, count: 0
  end
end
