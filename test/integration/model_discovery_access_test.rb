require "test_helper"
require_relative "../test_helpers/model_discovery_test_helper"

class ModelDiscoveryAccessTest < ActionDispatch::IntegrationTest
  include ModelDiscoveryTestHelper
  include ActiveJob::TestHelper
  setup do
    build_discovery_corpus
    sign_in_as users(:owner)
  end

  test "invalid configuration consent and changed preview retain input and queue nothing" do
    path = workspace_corpus_corpus_analyses_path(@workspace, @corpus)
    parameters = { processing_method: "model", scenario_limit: 2, configuration: discovery_configuration.to_json, input_digest: ModelCorpusDiscovery.digest(discovery_input) }
    with_corpus_approval do
      assert_no_difference("CorpusAnalysis.count") do
        post path, params: parameters
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /Confirm disclosure/
        assert_select "textarea[name=configuration]", text: discovery_configuration.to_json
        assert_select "input#corpus_disclose[checked]", count: 0
        post path, params: parameters.merge(configuration: "{incomplete", corpus_disclose: "1")
        assert_response :unprocessable_content
        assert_select "textarea[name=configuration]", text: "{incomplete"
        post path, params: parameters.merge(configuration: "null", corpus_disclose: "1")
        assert_response :unprocessable_content
      end
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Additional SOP", kind: "document", bytes: "New company evidence.")
      assert_no_difference("CorpusAnalysis.count") do
        post path, params: parameters.merge(corpus_disclose: "1")
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /preview changed/
        assert_select "input[name=input_digest][value='#{parameters[:input_digest]}']", count: 0
        assert_select "input#corpus_disclose[checked]", count: 0
        assert_select "summary", text: /Additional SOP/
      end
    end
  end

  test "oversized current previews and requests load no complete rows and queue nothing" do
    add_large_context_sources
    assert_no_difference([ "CorpusAnalysis.count", "CorpusAnalysisInput.count", "AuditEvent.count" ]) do
      assert_no_enqueued_jobs do
        assert_no_corpus_item_materialization do
          %w[model model_batch].each do |method|
            get new_workspace_corpus_corpus_analysis_path(@workspace, @corpus), params: { processing_method: method }
            assert_response :success
            assert_select "[role=status]", text: /10 MiB/
            assert_select "input[name=input_digest]", count: 0
            assert_select "input#corpus_disclose", count: 0
            post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: { processing_method: method, configuration: discovery_configuration.to_json, corpus_disclose: "1", scenario_limit: 2 }
            assert_response :unprocessable_content
            assert_select "[role=alert]", text: /10 MiB/
          end
          post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: { processing_method: "local", scenario_limit: 2 }
          assert_response :see_other
        end
      end
    end
  end

  test "oversized historic local model and batch views show repair without changing definitions or loading examples" do
    add_large_context_sources
    [ CorpusAnalysis::METHOD, ModelCorpusDiscovery::VERSION, BatchCorpusDiscovery::VERSION ].each do |method|
      analysis = build_fixed_analysis(processing_method: method, complete: true)
      definition = analysis.attributes
      ids = analysis.corpus_analysis_inputs.pluck(:corpus_item_id)
      assert_no_difference([ "CorpusAnalysisInput.count", "IssueCluster.count", "Scenario.count", "TaxonomyVersion.count", "AuditEvent.count" ]) do
        assert_no_enqueued_jobs do
          assert_no_corpus_item_materialization do
            2.times do
              get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
              assert_response :success
              assert_select "[role=alert]", text: /10 MiB/
              assert_select "p", text: /No partial source preview or candidates/
              assert_select "details.source-record", count: 0
              assert_select "input[value='Create selected scenarios']", count: 0
              assert_select "input[name=label]", count: 0
              assert_select "a.back-link[href='#{workspace_corpus_path(@workspace, @corpus)}']"
            end
          end
        end
      end
      assert_equal definition, analysis.reload.attributes
      assert_equal ids, analysis.corpus_analysis_inputs.pluck(:corpus_item_id)
    end
  end

  test "family focus counts fixed selection and paginates without narrowing analysis totals or writing" do
    analysis = build_selection_analysis
    path = workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
    selected_id = analysis.issue_clusters.joins(:cluster_members).where(cluster_members: { corpus_item_id: @snapshot.corpus_items.find_by!(external_id: "family-12").id }).sole.id
    unselected_ids = analysis.issue_clusters.order(:id).ids - [ selected_id ]
    definitions = [ analysis.attributes, analysis.corpus_analysis_inputs.order(:id).pluck(:corpus_item_id), analysis.issue_clusters.order(:id).map(&:attributes) ]
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations", bytes: [ { id: "new", title: "New export", content: "Different issue" } ].to_json)
    assert_no_difference([ "Scenario.count", "TaxonomyVersion.count", "AuditEvent.count", "CorpusAnalysis.count" ]) do
      assert_no_enqueued_jobs do
        get path, params: { family_focus: "No selected candidates" }
        assert_response :success
        assert_select "p", text: /1 candidate selected from 12 conversations.*1 of 12 term clusters represented/
        assert_select "option", text: "All families (12)"
        assert_select "option", text: "With selected candidates (1)"
        assert_select "option[selected]", text: "No selected candidates (11)"
        assert_select "section[aria-labelledby^=cluster-]", count: 10
        unselected_ids.first(10).each { |id| assert_select "h2#cluster-#{id}" }
        assert_select "h2#cluster-#{selected_id}", count: 0
        assert_select "a[href='#{workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, analysis, unselected_ids.first)}']"
        next_link = css_select("a").find { |link| link.text == "Next records" }["href"]
        assert_equal "No selected candidates", Rack::Utils.parse_query(URI(next_link).query)["family_focus"]
        get next_link
        assert_response :success
        assert_select "section[aria-labelledby^=cluster-]", count: 1
        assert_select "h2#cluster-#{unselected_ids.last}"
        assert_select "a", text: "Next records", count: 0
        refresh_link = css_select("a").find { |link| link.text == "Refresh result" }["href"]
        assert_equal "No selected candidates", Rack::Utils.parse_query(URI(refresh_link).query)["family_focus"]
        get path, params: { family_focus: "With selected candidates" }
        assert_response :success
        assert_select "section[aria-labelledby^=cluster-]", count: 1
        assert_select "h2#cluster-#{selected_id}"
        assert_select "summary", text: /Certificate expiry — selected candidate/
      end
    end
    assert_equal definitions, [ analysis.reload.attributes, analysis.corpus_analysis_inputs.order(:id).pluck(:corpus_item_id), analysis.issue_clusters.order(:id).map(&:attributes) ]
  end

  test "empty and invalid family focus are repairable read-only pages and cannot supply a URL scheme" do
    with_discovery_response do
      analysis = request_model_analysis
      CorpusAnalysisJob.perform_now(analysis.id)
      path = workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
      assert_no_difference([ "Scenario.count", "TaxonomyVersion.count", "AuditEvent.count" ]) do
        assert_no_enqueued_jobs do
          get path, params: { family_focus: "No selected candidates" }
          assert_response :success
          assert_select "option[selected]", text: "No selected candidates (0)"
          assert_select "[role=status]", text: /No families in this view/
          assert_select "section[aria-labelledby^=cluster-]", count: 0
          get path, params: { family_focus: "<script>invalid</script>", host: "javascript:alert(1)//", protocol: "javascript" }
          assert_response :success
          assert_select "[role=alert]", text: /Choose a family focus/
          assert_select "select[aria-invalid=true][aria-describedby=family-focus-error]"
          assert_select "script", text: /invalid/, count: 0
          assert_select "section[aria-labelledby^=cluster-]", count: 0
          assert_select "a", text: "All families", count: 1
          assert_select "a[href^='javascript:']", count: 0
          get path, params: { family_focus: "All families", page: 10000 }
          assert_response :success
          assert_select "[role=status]", text: /No families on this page/
        end
      end
    end
  end

  test "viewers inspect escaped model evidence but cannot request interrupt or cross a workspace" do
    response = discovery_response.merge("reason" => "<script>untrusted proposal</script>")
    with_discovery_response(response:) do
      @analysis = request_model_analysis
      CorpusAnalysisJob.perform_now(@analysis.id)
    end
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference([ "CorpusAnalysis.count", "CorpusAnalysisResult.count", "AuditEvent.count", "TaxonomyVersion.count" ]) do
      get workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
      assert_response :success
      assert_select "script", text: /untrusted proposal/, count: 0
      assert_select "h3", text: "Membership quote", count: 3
      assert_select "form[method=get] input[type=submit]", count: 1
      assert_select "main form[method=post]", count: 0
      get workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis), params: { family_focus: "With selected candidates" }
      assert_response :success
      assert_select "option[selected]", text: "With selected candidates (2)"
      get new_workspace_corpus_corpus_analysis_path(@workspace, @corpus)
      assert_response :forbidden
      post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: {}
      assert_response :forbidden
      post interrupt_workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
      assert_response :forbidden
      get workspace_corpus_corpus_analysis_path(workspaces(:beta_support), @corpus, @analysis)
      assert_response :not_found
    end
    @snapshot.source.update!(expires_at: 1.minute.ago)
    get workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
    assert_response :not_found
  end
end
