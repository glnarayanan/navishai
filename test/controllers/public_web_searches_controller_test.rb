require "test_helper"

class PublicWebSearchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    @task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile:,
      title: "Research public status", input_context: "Use public evidence.",
      expected_output: "Return cited sources."
    )
    sign_in_as @owner.user
  end

  test "writer runs a redacted search and reviews a safe external citation" do
    client = Object.new
    client.define_singleton_method(:web_search!) do |workspace_key:, request_key:, query:, **|
      {
        "protocol_version" => "v1", "workspace_key" => workspace_key,
        "request_key" => request_key, "query" => query, "provider_key" => "searxng",
        "policy_decision" => "allowed", "cost_units" => 2, "retrieved_at" => "2026-08-24T12:00:00Z",
        "results" => [ {
          "rank" => 1, "title" => "Public incident", "url" => "https://status.example.com/incidents/1",
          "excerpt" => "Service recovered.", "published_at" => "2026-08-24T11:00:00Z"
        } ]
      }
    end

    with_runner_client(client) do
      assert_difference [ "PublicWebSearch.count", "PublicWebSearchResult.count" ], 1 do
        post search_path, params: {
          request_key: "web:controller", public_web_query: "alice@example.net status incident"
        }
      end
    end
    assert_redirected_to workspace_support_case_crew_task_path(@workspace, @support_case, @task)

    get workspace_support_case_crew_task_path(@workspace, @support_case, @task)
    assert_response :success
    assert_select ".public-web-warning", text: /untrusted evidence/
    assert_select ".public-web-meta", text: /Sensitive terms removed/
    assert_select ".public-web-results a[href='https://status.example.com/incidents/1'][target='_blank'][rel='noopener noreferrer']",
      text: "Public incident"
    assert_select ".public-web-result-url", text: "https://status.example.com/incidents/1"
    assert_select ".public-web-results code", text: /public-web:\/\//
  end

  test "viewer cannot search and foreign task paths fail closed" do
    viewer = @workspace.memberships.create!(
      user: User.create!(email_address: "public-web-viewer@example.com", password: "password12345", verified_at: Time.current),
      role: :viewer
    )
    sign_in_as viewer.user
    get workspace_support_case_crew_task_path(@workspace, @support_case, @task)
    assert_response :success
    assert_select ".public-web-form", count: 0
    assert_no_difference "PublicWebSearch.count" do
      post search_path, params: { request_key: "web:forged", public_web_query: "public incident" }
    end
    assert_response :forbidden, flash.to_hash.inspect

    foreign_case = create_support_case(
      workspace: workspaces(:beta_support), contact: contacts(:bob), membership: memberships(:outsider_beta)
    )
    post workspace_support_case_crew_task_public_web_searches_path(@workspace, foreign_case, @task),
      params: { request_key: "web:foreign", public_web_query: "public incident" }
    assert_response :not_found
  end

  private
    def search_path
      workspace_support_case_crew_task_public_web_searches_path(@workspace, @support_case, @task)
    end

    def with_runner_client(client)
      original = RunnerClient.method(:new)
      RunnerClient.define_singleton_method(:new) { client }
      yield
    ensure
      RunnerClient.define_singleton_method(:new, original)
    end
end
