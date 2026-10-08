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

  test "landing offers a pilot by email and a footer whose links resolve" do
    get root_path

    assert_select ".landing-close a.button[href=?]", "mailto:hello@navishai.com?subject=NavishAI%20pilot", text: "Request a pilot"
    assert_select ".landing-close a[href=?]", "mailto:hello@navishai.com", text: "hello@navishai.com"
    assert_select ".landing-close", text: /Built by a Support leader with 13\+ years in B2B SaaS post-sales/
    assert_select "main.landing a[href=?]", new_session_path, text: "Sign in to the lab", count: 1
    assert_select "footer.landing-footer", text: /© 2026 NavishAI/
    assert_select "footer.landing-footer nav[aria-label=Footer] a" do |links|
      assert_equal [ "mailto:hello@navishai.com", privacy_path, terms_path, "#landing-title" ], links.map { |link| link["href"] }
    end
    assert_select "#landing-title", count: 1

    [ privacy_path, terms_path ].each do |path|
      get path
      assert_response :success
    end
  end

  test "privacy and terms render signed out with the lab data boundaries and pre-launch notice" do
    assert_no_difference [ "AuditEvent.count", "Corpus.count" ] do
      get privacy_path
    end
    assert_response :success
    assert_select "title", text: "Privacy — NavishAI"
    assert_select "h1#privacy-page-title", text: "Privacy"
    assert_select "dt", text: "Local by default"
    assert_select "dt", text: "Explicit external disclosure"
    assert_select "dt", text: "No training on customer data"
    assert_select "dd", text: /do not remove all PII/
    assert_select "dd", text: /cannot recall data already sent/
    assert_select "dd", text: /navishai_theme/
    assert_select "footer.landing-footer a[href=?]", "#privacy-page-title", text: "Back to top"
    assert_select "script[src]:not([src^='/'])", count: 0

    get terms_path
    assert_response :success
    assert_select "title", text: "Terms — NavishAI"
    assert_select "h1#terms-page-title", text: "Terms"
    assert_select "dd", text: /no managed service and no public signup/
    assert_select "dd", text: /provided as-is/
    assert_select "main a[href=?]", "mailto:hello@navishai.com"
    assert_select "footer.landing-footer a[href=?]", "#terms-page-title", text: "Back to top"
    assert_select "[style], iframe, main img, main form", count: 0
  end

  test "signed-in visitors can still read privacy and terms" do
    sign_in_as users(:owner)

    get privacy_path
    assert_response :success
    get terms_path
    assert_response :success
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
