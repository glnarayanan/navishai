require "test_helper"

class AppShellTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    sign_in_as users(:owner)
  end

  test "workspace pages share one sidebar with role-scoped links" do
    get workspace_path(@workspace)
    assert_response :success
    assert_select "aside#app-sidebar[popover] nav[aria-label=Workspace]" do
      assert_select "a[aria-current=page]", text: "Overview"
      assert_select "a", text: "People and access"
      assert_select "a", text: "Settings"
    end
    assert_select "nav[aria-label='Corpus sections']", count: 0
    assert_select "#account-menu[popover] .theme-switch[role=radiogroup] [role=radio]", count: 3
    assert_select "#account-menu button", text: "Sign out"
    assert_select "#workspace-menu a[aria-current=true] .menu-item-label", text: @workspace.name
  end

  test "corpus detail pages keep the corpus sections and mark their place" do
    corpus = @workspace.corpora.create!(name: "Shell corpus")
    get workspace_corpus_path(@workspace, corpus)
    assert_select "nav[aria-label='Corpus sections'] a", count: 9
    assert_select "nav[aria-label='Corpus sections'] a[aria-current=page]", text: "Sources"

    get workspace_corpus_evaluation_runs_path(@workspace, corpus)
    assert_select "nav[aria-label='Corpus sections'] a[aria-current=page]", text: "Runs"
    assert_select "nav[aria-label=Breadcrumb] [aria-current=page]", text: "Runs"

    suite = corpus.eval_suites.create!(workspace: @workspace, name: "Shell suite", kind: "evaluation")
    get workspace_corpus_eval_suite_path(@workspace, corpus, suite)
    assert_select "nav[aria-label=Breadcrumb] a[href=?]", workspace_corpus_eval_suites_path(@workspace, corpus), text: "Eval suites"
    assert_select "nav[aria-label=Breadcrumb] [aria-current=page]", text: "Shell suite"
  end

  test "signed-out pages keep a slim header with the theme radiogroup" do
    delete session_path
    get new_session_path
    assert_select "header.public-header .theme-switch [role=radio]", count: 3
    assert_select "#app-sidebar", count: 0
  end
end
