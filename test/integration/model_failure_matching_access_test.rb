require "test_helper"
require_relative "../test_helpers/model_failure_matching_test_helper"

class ModelFailureMatchingAccessTest < ActionDispatch::IntegrationTest
  include ModelFailureMatchingTestHelper
  setup do
    build_model_matching_fixture
    sign_in_as users(:owner)
  end

  test "default source stays local and preview has complete fixed data without creating an attempt" do
    with_test_method(ModelFailureMatcher, :input, ->(*) { flunk "Default source invoked optional workflow" }) do
      get source_path
      assert_response :success
      assert_select "a", text: "Preview optional model matching"
      assert_select "meta[name=turbo-cache-control]", count: 0
    end
    assert_no_difference [ "ModelFailureMatching.count", "ModelFailureMatchingResult.count", "AuditEvent.count" ] do
      get source_path, params: { model_matching_item_id: @item.id }
      assert_response :success
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_select "meta[name=turbo-cache-control][content=no-cache]"
      assert_select "#model-matching-#{@item.id}[open]"
      assert_select "button", text: "Request matching suggestions once", count: 0
      post preview_path, params: { corpus_item_id: @item.id, configuration: matching_configuration.to_json }
      assert_response :success
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_select "meta[name=turbo-cache-control][content=no-cache]"
      assert_select "h4", text: "Confirm this exact matching disclosure"
      assert_select "input[name=request_digest]"
      assert_select "input[name=disclose][checked]", count: 0
      assert_select "#model-matching-#{@item.id} pre", text: /Request quota exhausted; retry after cooldown/
      assert_select "#model-matching-#{@item.id} pre", text: /PRIVATE_HIDDEN_FACT|PRIVATE_REVIEW_NOTE|PRIVATE_IMPORTED_CORRECTION/, count: 0
    end
  end

  test "bad configuration consent and stale previews preserve repair fields and queue nothing" do
    with_matching_approval do
      assert_no_difference "ModelFailureMatching.count" do
        post preview_path, params: { corpus_item_id: @item.id, configuration: "{broken" }
        assert_response :unprocessable_content
        assert_equal "no-store", response.headers["Cache-Control"]
        assert_select "textarea[name=configuration]", text: "{broken"
        assert_select "#model-matching-#{@item.id} [role=alert]", text: /not valid JSON/
        parameters = matching_parameters
        post request_path, params: parameters.except(:disclose)
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /Confirm the exact matching endpoint/
        assert_select "textarea[name=configuration]", text: matching_configuration.to_json
        assert_select "input[name=disclose][checked]", count: 0
        @paraphrase.scenario.revise!(membership: @membership, base_version_id: @paraphrase.id, attributes: { title: "Later expert version" })
        post request_path, params: parameters
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /Matching preview changed/
        assert_select "button", text: "Request matching suggestions once", count: 0
      end
      post preview_path, params: { corpus_item_id: @item.id, configuration: matching_configuration.to_json }
      assert_response :success
      assert_select "input[name=disclose][checked]", count: 0
    end
  end

  test "result is escaped read-only expiry hidden and foreign requests and viewers fail closed" do
    model_response = matching_response
    model_response["suggestions"][0]["reason"] = "<script>untrusted model text</script>"
    with_matching_response(response: model_response) do
      post request_path, params: matching_parameters
      assert_response :see_other
      request = ModelFailureMatching.where(corpus: @corpus).sole
      assert_equal "queued", request.state
      ModelFailureMatchingJob.perform_now(request.id)
      follow_redirect!
      assert_response :success
      assert_select "h3", text: "Model suggestions — not expert decisions"
      assert_select "script", text: /untrusted model text/, count: 0
      assert_select "dd", text: "<script>untrusted model text</script>"
      assert_select "h4", text: /Match suggestion/
      assert_select "h4", text: /No-match suggestion/
      assert_select "h4", text: /Uncertain suggestion/
      assert_empty TraceScenarioDecision.where(corpus: @corpus)

      sibling = @workspace.corpora.create!(name: "Other corpus")
      sibling_item = CorpusIntake.call(corpus: sibling, membership: @membership, name: "Other traces", kind: "traces", bytes: File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).corpus_items.sole
      post request_path, params: matching_parameters.merge(corpus_item_id: sibling_item.id)
      assert_response :not_found
      get workspace_corpus_source_path(workspaces(:beta_support), @corpus, @item.source_snapshot.source), params: { model_matching_item_id: @item.id }
      assert_response :not_found
      Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
      sign_in_as users(:teammate)
      get source_path, params: { model_matching_item_id: @item.id }
      assert_response :success
      assert_select "h3", text: "Model suggestions — not expert decisions"
      assert_select "#model-matching-#{@item.id} button[type=submit]", count: 0
      post preview_path, params: { corpus_item_id: @item.id, configuration: matching_configuration.to_json }
      assert_response :forbidden
      post request_path, params: matching_parameters
      assert_response :forbidden
      post interrupt_model_matching_workspace_corpus_source_path(@workspace, @corpus, @item.source_snapshot.source), params: { corpus_item_id: @item.id, matching_request_id: request.id }
      assert_response :forbidden
      @document.source_snapshot.source.update!(expires_at: 1.second.ago)
      get source_path, params: { model_matching_item_id: @item.id }
      assert_response :success
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_select "#model-matching-#{@item.id} [role=status]", text: /stay hidden/
      assert_select "h3", text: "Model suggestions — not expert decisions", count: 0
      assert_select "#model-matching-#{@item.id} pre", count: 0
    end
  end

  test "member writers retain the proposal writer contract after separate operator approval" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :member)
    sign_in_as users(:teammate)
    with_matching_approval do
      post preview_path, params: { corpus_item_id: @item.id, configuration: matching_configuration.to_json }
      assert_response :success
      assert_select "input[type=checkbox][name=disclose][required]"
      post request_path, params: matching_parameters
      assert_response :see_other
      request = ModelFailureMatching.where(corpus: @corpus).sole
      assert_equal users(:teammate), request.requested_by
      assert_equal "queued", request.state
    end
  end

  private
    def source_path
      workspace_corpus_source_path(@workspace, @corpus, @item.source_snapshot.source)
    end

    def preview_path
      preview_model_matching_workspace_corpus_source_path(@workspace, @corpus, @item.source_snapshot.source)
    end

    def request_path
      request_model_matching_workspace_corpus_source_path(@workspace, @corpus, @item.source_snapshot.source)
    end

    def matching_parameters
      input = ModelFailureMatcher.input(@item)
      { corpus_item_id: @item.id, configuration: matching_configuration.to_json, input_digest: ModelFailureMatcher.digest(input),
        request_digest: ModelFailureMatcher.request_digest(input, matching_configuration), disclose: "1", endpoint_confirmation: HTTP_ENDPOINT }
    end
end
