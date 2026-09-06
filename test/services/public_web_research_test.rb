require "test_helper"

class PublicWebResearchTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    @investigator = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    @task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: @investigator,
      title: "Check the public incident record", input_context: "Use public evidence only.",
      expected_output: "Return dated sources and state uncertainty."
    )
    @response = {
      "protocol_version" => "v1", "workspace_key" => @workspace.runner_key,
      "request_key" => "search:one", "query" => "status incident",
      "provider_key" => "searxng", "policy_decision" => "allowed", "cost_units" => 1,
      "retrieved_at" => "2026-08-24T12:00:00Z",
      "results" => [ {
        "rank" => 1, "title" => "Incident report", "url" => "https://status.example.com/incidents/1",
        "excerpt" => "The service recovered.", "published_at" => "2026-08-24T11:00:00Z"
      } ]
    }
  end

  test "stores a normalized result and attributable audit trail" do
    client = client_returning(@response)

    assert_difference [ "PublicWebSearch.count", "PublicWebSearchResult.count" ], 1 do
      @search = PublicWebResearch.perform!(
        workspace: @workspace, membership: @owner, task: @task,
        query: "status incident", request_key: "search:one", client:
      )
    end

    assert @search.completed?
    assert_equal "searxng", @search.provider_key
    assert_equal 1, @search.cost_units
    assert_equal "Incident report", @search.results.sole.title
    assert_equal Time.iso8601("2026-08-24T11:00:00Z"), @search.results.sole.published_at
    assert_equal %w[public_web.search_requested public_web.search_completed],
      AuditEvent.where(subject_type: "PublicWebSearch", subject_id: @search.id).order(:id).pluck(:action)
  end

  test "redacts personal and secret values before storage and runner disclosure" do
    captured = nil
    response = @response.merge("request_key" => "search:redacted",
      "query" => "Find [redacted email] at [redacted phone] using [redacted secret] after 2026-08-24")
    client = Object.new
    client.define_singleton_method(:web_search_catalog!) { |**| { "default_provider_key" => "searxng", "provider_keys" => [ "searxng" ] } }
    client.define_singleton_method(:web_search!) do |**attributes|
      captured = attributes
      response
    end

    search = PublicWebResearch.perform!(
      workspace: @workspace, membership: @owner, task: @task,
      query: "Find alice@example.net at +1 (212) 555-1212 using token=customer-secret after 2026-08-24",
      request_key: "search:redacted", client:
    )

    assert_equal "Find [redacted email] at [redacted phone] using [redacted secret] after 2026-08-24", search.query
    assert_equal search.query, captured.fetch(:query)
    assert_equal "redacted", search.policy_decision
    assert_not_includes search.query, "alice@example.net"
    assert_not_includes search.query, "customer-secret"
  end

  test "ambiguous retry reuses one durable request while definite failure is terminal" do
    ambiguous = Object.new
    ambiguous.define_singleton_method(:web_search_catalog!) { |**| { "default_provider_key" => "searxng", "provider_keys" => [ "searxng" ] } }
    ambiguous.define_singleton_method(:web_search!) { |**| raise RunnerClient::AmbiguousResult, "unknown" }
    assert_raises(RunnerClient::AmbiguousResult) do
      PublicWebResearch.perform!(
        workspace: @workspace, membership: @owner, task: @task,
        query: "status incident", request_key: "search:one", client: ambiguous
      )
    end
    assert_equal "searching", @workspace.public_web_searches.sole.status

    search = PublicWebResearch.perform!(
      workspace: @workspace, membership: @owner, task: @task,
      query: "status incident", request_key: "search:one", client: client_returning(@response)
    )
    assert search.completed?
    assert_equal 1, AuditEvent.where(action: "public_web.search_requested", subject_id: search.id).count
    assert_equal 1, AuditEvent.where(action: "public_web.search_retried", subject_id: search.id).count

    unavailable = Object.new
    unavailable.define_singleton_method(:web_search_catalog!) { |**| { "default_provider_key" => "searxng", "provider_keys" => [ "searxng" ] } }
    unavailable.define_singleton_method(:web_search!) { |**| raise RunnerClient::Unavailable, "offline" }
    assert_raises(RunnerClient::Unavailable) do
      PublicWebResearch.perform!(
        workspace: @workspace, membership: @owner, task: @task,
        query: "another incident", request_key: "search:failed", client: unavailable
      )
    end
    failed = @workspace.public_web_searches.find_by!(request_key: "search:failed")
    assert failed.failed?
    assert_equal "unavailable", failed.failure_code
  end

  test "policy, tenancy, idempotency, and append-only boundaries fail closed" do
    coordinator = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    denied_task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: coordinator,
      title: "Coordinate", input_context: "Use case facts.", expected_output: "Create a bounded plan."
    )
    assert_raises(PublicWebResearch::PolicyDenied) do
      PublicWebResearch.perform!(
        workspace: @workspace, membership: @owner, task: denied_task,
        query: "public query", request_key: "search:denied", client: client_returning(@response)
      )
    end

    search = PublicWebResearch.perform!(
      workspace: @workspace, membership: @owner, task: @task,
      query: "status incident", request_key: "search:one", client: client_returning(@response)
    )
    assert_raises(PublicWebResearch::Error) do
      PublicWebResearch.perform!(
        workspace: @workspace, membership: @owner, task: @task,
        query: "changed query", request_key: "search:one", client: client_returning(@response)
      )
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      PublicWebResearch.perform!(
        workspace: workspaces(:beta_support), membership: memberships(:outsider_beta), task: @task,
        query: "status incident", request_key: "search:foreign", client: client_returning(@response)
      )
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      PublicWebSearch.transaction(requires_new: true) { PublicWebSearch.where(id: search.id).update_all(query: "tampered") }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      PublicWebSearch.transaction(requires_new: true) { PublicWebSearch.where(id: search.id).update_all(id: search.id + 1_000_000) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      PublicWebSearchResult.transaction(requires_new: true) { PublicWebSearchResult.where(id: search.results.sole.id).update_all(title: "tampered") }
    end

    searching = @workspace.public_web_searches.create!(
      crew_task: @task, request_key: "search:unfinished", query: "unfinished search",
      requested_by_membership: @owner, requested_by_user: @owner.user
    )
    assert_raises(ActiveRecord::StatementInvalid) do
      PublicWebSearchResult.transaction(requires_new: true) do
        searching.results.create!(
          workspace: @workspace, rank: 1, title: "Uncommitted", url: "https://example.com/uncommitted",
          excerpt: "Not complete.", retrieved_at: Time.current, content_digest: "a" * 64
        )
      end
    end
  end

  test "new searches resolve the default once and retries preserve it after settings change" do
    client = client_returning(@response)
    client.define_singleton_method(:web_search!) { |**| raise RunnerClient::AmbiguousResult, "unknown" }
    assert_raises(RunnerClient::AmbiguousResult) do
      PublicWebResearch.perform!(workspace: @workspace, membership: @owner, task: @task,
        query: "status incident", request_key: "search:one", client:)
    end
    search = @workspace.public_web_searches.sole
    assert_equal "searxng", search.requested_provider_key
    @workspace.update!(web_search_provider_key: "tavily")
    response = @response
    requested = nil
    client.define_singleton_method(:web_search_catalog!) { |**| raise "retry must not need catalog" }
    client.define_singleton_method(:web_search!) { |**attributes| requested = attributes; response }
    PublicWebResearch.perform!(workspace: @workspace, membership: @owner, task: @task,
      query: "status incident", request_key: "search:one", client:)
    assert_equal "searxng", requested.fetch(:provider_key)
    assert search.reload.completed?
    assert_raises(ActiveRecord::StatementInvalid) do
      PublicWebSearch.where(id: search.id).update_all(requested_provider_key: "tavily")
    end
  end

  test "an explicit workspace provider does not depend on the catalog and rejects another provider response" do
    @workspace.update!(web_search_provider_key: "tavily")
    client = client_returning(@response)
    client.define_singleton_method(:web_search_catalog!) { |**| raise "not needed" }
    assert_raises(RunnerClient::MalformedResponse) do
      PublicWebResearch.perform!(workspace: @workspace, membership: @owner, task: @task,
        query: "status incident", request_key: "search:one", client:)
    end
    search = @workspace.public_web_searches.sole
    assert_equal "tavily", search.requested_provider_key
    assert search.failed?
    assert_empty search.results
  end

  private
    def client_returning(response)
      Object.new.tap do |client|
        client.define_singleton_method(:web_search_catalog!) { |**| { "default_provider_key" => "searxng", "provider_keys" => [ "searxng" ] } }
        client.define_singleton_method(:web_search!) { |**| response }
      end
    end
end
