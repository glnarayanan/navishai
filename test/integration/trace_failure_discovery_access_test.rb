require "test_helper"
require_relative "../test_helpers/trace_failure_discovery_test_helper"

class TraceFailureDiscoveryAccessTest < ActionDispatch::IntegrationTest
  include TraceFailureDiscoveryTestHelper
  include ActiveJob::TestHelper
  setup { build_trace_discovery; sign_in_as users(:owner) }

  test "request requires renewed consent exact preview fixed settings and corpus purpose approval" do
    path = workspace_corpus_trace_failure_discoveries_path(@workspace, @corpus)
    parameters = { configuration: discovery_configuration.to_json, input_digest: TraceFailureDiscoveryPreview.digest(trace_discovery_input) }
    with_corpus_approval do
      assert_no_difference [ "TraceFailureDiscovery.count", "AuditEvent.count" ] do
        assert_no_enqueued_jobs do
          post path, params: parameters
          assert_response :unprocessable_content
          assert_select "[role=alert]", text: /Confirm the exact contents/
          assert_select "textarea[name=configuration]", text: discovery_configuration.to_json
          assert_select "input#corpus_disclose[checked]", count: 0
          post path, params: parameters.merge(configuration: "{incomplete", corpus_disclose: "1")
          assert_response :unprocessable_content
          assert_select "textarea[name=configuration]", text: "{incomplete"
          assert_select "input#corpus_disclose[checked]", count: 0
          post path, params: parameters.merge(configuration: "null", corpus_disclose: "1")
          assert_response :unprocessable_content
          post path, params: parameters.merge(input_digest: "outdated", corpus_disclose: "1")
          assert_response :unprocessable_content
          assert_select "[role=alert]", text: /preview changed/
        end
      end
      assert_enqueued_with(job: TraceFailureDiscoveryJob) do
        post path, params: parameters.merge(corpus_disclose: "1")
        assert_response :see_other
      end
    end
    with_endpoint_approval do
      assert_no_difference "TraceFailureDiscovery.count" do
        post path, params: parameters.merge(corpus_disclose: "1")
        assert_response :unprocessable_content
      end
    end
  end

  test "read only refresh does not send and viewers cannot mutate or cross tenants or corpora" do
    with_trace_discovery_response { @discovery = request_trace_discovery; TraceFailureDiscoveryJob.perform_now(@discovery.id) }
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    calls = []
    with_trace_discovery_response(calls:) do
      assert_no_difference [ "TraceFailureDiscovery.count", "TraceFailureReview.count", "AuditEvent.count", "Scenario.count" ] do
        assert_no_enqueued_jobs do
          2.times do
            get workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, @discovery)
            assert_response :success
            assert_select "#trace-accounting", text: /4 of 4.*2 proposed failures, 1 no finding, 1 abstention/
            assert_select "main form[method=post]", count: 0
            assert_select "script", text: /untrusted/, count: 0
          end
          get workspace_corpus_trace_failure_discoveries_path(@workspace, @corpus)
          assert_response :success
          assert_select "a", text: "Preview discovery contents", count: 0
          get new_workspace_corpus_trace_failure_discovery_path(@workspace, @corpus)
          assert_response :forbidden
          post workspace_corpus_trace_failure_discoveries_path(@workspace, @corpus)
          assert_response :forbidden
          %i[interrupt review draft].each do |action|
            post public_send("#{action}_workspace_corpus_trace_failure_discovery_path", @workspace, @corpus, @discovery)
            assert_response :forbidden
          end
          get workspace_corpus_trace_failure_discovery_path(workspaces(:beta_support), @corpus, @discovery)
          assert_response :not_found
          other = @workspace.corpora.create!(name: "Other local corpus")
          get workspace_corpus_trace_failure_discovery_path(@workspace, other, @discovery)
          assert_response :not_found
        end
      end
      assert_empty calls
    end
  end

  test "expired contents are hidden and empty or oversized previews offer recovery without a partial request" do
    with_trace_discovery_response do
      discovery = request_trace_discovery
      TraceFailureDiscoveryJob.perform_now(discovery.id)
      @document.source_snapshot.source.update!(expires_at: 1.second.ago)
      get workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, discovery)
      assert_response :success
      assert_select "[role=alert]", text: /contents, findings and decisions are hidden/
      assert_select "pre", count: 0
      assert_select "main form", count: 0
      assert_not_includes response.body, "destructive delete"
    end
    empty = @workspace.corpora.create!(name: "Empty fixture")
    get new_workspace_corpus_trace_failure_discovery_path(@workspace, empty)
    assert_response :success
    assert_select "[role=alert]", text: /1–50 complete traces/
    assert_select "main form", count: 0
    assert_select "a", text: "Inspect the corpus"
  end

  test "expert repair preserves their reason and only their latest acceptance permits empty expectation draft" do
    with_trace_discovery_response { @discovery = request_trace_discovery; TraceFailureDiscoveryJob.perform_now(@discovery.id) }
    review_path = review_workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, @discovery)
    item = @items.fetch("unreported")
    reason = "Expert inspected <script>this</script> source, not a model label."
    assert_no_difference [ "TraceFailureReview.count", "Scenario.count" ] do
      post review_path, params: { corpus_item_id: item.id, decision: "unsupported", reason: }
      assert_response :unprocessable_content
      assert_select "#reason-#{item.id}[aria-invalid=true]", text: reason
      assert_select "#review-error-#{item.id}[role=alert]", text: /Decision/
      assert_select "script", text: /this/, count: 0
    end
    post review_path, params: { corpus_item_id: item.id, decision: "accept", reason: }
    assert_response :see_other
    review = @discovery.trace_failure_reviews.sole
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :member)
    sign_in_as users(:teammate)
    assert_no_difference "Scenario.count" do
      post draft_workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, @discovery), params: { review_id: review.id }
      assert_response :see_other
      follow_redirect!
      assert_select "[role=alert]", text: /Accept this proposed failure yourself/
    end
    sign_in_as users(:owner)
    assert_difference "Scenario.count", 1 do
      post draft_workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, @discovery), params: { review_id: review.id }
      assert_response :see_other
    end
    draft = @corpus.scenarios.find_by!(corpus_item: item).current_version
    assert_equal ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }, draft.requirements
    assert_not draft.approved?
    assert_equal 0, RegressionCase.where(corpus: @corpus).count
    assert_equal 0, HumanLabel.where(corpus: @corpus).count
  end

  test "changed comparison set hides acceptance and blocks stale review and draft without rewriting history" do
    with_trace_discovery_response { @discovery = request_trace_discovery; TraceFailureDiscoveryJob.perform_now(@discovery.id) }
    item = @items.fetch("unreported")
    review = TraceFailureReview.append!(discovery: @discovery, item:, membership: @membership, decision: "accept", reason: "Before the new policy")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "New entitlement policy", kind: "document", bytes: "New entitlement rule.")
    get workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, @discovery)
    assert_response :success
    assert_select "[role=status]", text: /fixed history, not a current gap assessment/
    assert_select "input[value='Save expert decision']", count: 0
    assert_select "button", text: "Open unapproved scenario draft", count: 0
    assert_no_difference [ "TraceFailureReview.count", "Scenario.count" ] do
      post review_workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, @discovery), params: { corpus_item_id: item.id, decision: "accept", reason: "Stale request" }
      assert_response :unprocessable_content
      post draft_workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, @discovery), params: { review_id: review.id }
      assert_response :see_other
    end
    assert_equal "proposal", @discovery.trace_failure_discovery_result.result_content.fetch("decision")
  end
end
