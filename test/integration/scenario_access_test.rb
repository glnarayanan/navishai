require "test_helper"
require_relative "../test_helpers/scenario_test_helper"

class ScenarioAccessTest < ActionDispatch::IntegrationTest
  include ScenarioTestHelper

  setup do
    build_scenarios
    sign_in_as users(:owner)
  end

  test "document lookup finds later current evidence and retains it through a failed revision" do
    100.times do |index|
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Earlier document #{index}", kind: "document", bytes: "Earlier company guidance #{index}.")
    end
    item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Signing policy", kind: "document", bytes: "Inspect the private quasar boundary before escalation.").corpus_items.sole
    original = @scenario.current_version
    path = workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    assert_no_difference [ "ScenarioVersion.count", "ScenarioReview.count", "AuditEvent.count", "HumanLabel.count", "ScenarioProposal.count" ] do
      assert_no_enqueued_jobs do
        get path
        assert_response :success
        assert_select "#document-search [role=status]", text: /\A102 matching documents/
        assert_select "select[name=evidence_item_id] option", count: 101
        assert_select "select[name=evidence_item_id] option[value='#{item.id}']", count: 0
        get path, params: { corpus_query: "  QUASAR  " }
        assert_response :success
        assert_select "#document-search [role=status]", text: /\A1 matching document/
        assert_select "select[name=evidence_item_id] option[value='#{item.id}']", text: item.title
        assert_select "select[name=evidence_item_id] option[value='#{@knowledge.id}']", count: 0
        assert_select "input[name=corpus_query][type=hidden][value='  QUASAR  ']"
        assert_select "textarea[name=excerpt]", text: ""
      end
      patch path, params: { corpus_query: "  QUASAR  ", version_id: original.id, evidence_item_id: item.id,
        evidence_kind: "expectation", excerpt: "Keep this invalid excerpt", scenario: { title: "Keep my expert edit", known_facts: "broken", hidden_facts: "{}" } }
      assert_response :unprocessable_content
      assert_select "#document-search [role=status]", text: /\A1 matching document/
      assert_select "select[name=evidence_item_id] option[selected][value='#{item.id}']"
      assert_select "textarea[name=excerpt]", text: "Keep this invalid excerpt"
      assert_select "input[name='scenario[title]'][value='Keep my expert edit']"
      assert_select "input[name=corpus_query][type=search][value='  QUASAR  ']"
    end
    assert_difference "ScenarioVersion.count", 1 do
      patch path, params: { corpus_query: "  QUASAR  ", version_id: original.id, evidence_item_id: item.id,
        evidence_kind: "expectation", excerpt: item.content, scenario: { title: "Explicit company-backed revision", known_facts: original.known_facts.to_json, hidden_facts: "{}" } }
      assert_response :see_other
    end
    version = @scenario.reload.current_version
    assert_equal item.content, version.scenario_evidence.find_by!(corpus_item: item).excerpt
    assert_empty version.scenario_reviews
    assert_not_equal original.id, version.id
  end

  test "document lookup excludes foreign stale expired and conversation records" do
    foreign = @workspace.corpora.create!(name: "Foreign documents")
    CorpusIntake.call(corpus: foreign, membership: @membership, name: "Private foreign quasar", kind: "document", bytes: "Quasar boundary.")
    expired = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Expired quasar", kind: "document", bytes: "Quasar boundary.")
    expired.source.update!(expires_at: 1.minute.ago)
    stale = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Revised policy", kind: "document", bytes: "Old quasar boundary.")
    current = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Revised policy", kind: "document", bytes: "Current nebula policy.")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Unrelated conversations", kind: "conversations", bytes: [ { id: "quasar", title: "Quasar boundary", content: "Not company-document evidence." } ].to_json)
    path = workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    get path, params: { corpus_query: "quasar" }
    assert_response :success
    assert_select "#document-search [role=status]", text: /\A0 matching documents/
    assert_select "select[name=evidence_item_id] option", count: 1
    assert_not_includes response.body, "Private foreign quasar"
    get path, params: { corpus_query: "nebula" }
    assert_response :success
    assert_select "select[name=evidence_item_id] option[value='#{current.corpus_items.sole.id}']"
    assert_select "select[name=evidence_item_id] option[value='#{stale.corpus_items.sole.id}']", count: 0
  end

  test "document lookup escapes literals bounds input and retains an explicitly selected trace" do
    document = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Literal %_\\ policy", kind: "document", bytes: "Current Unicode 雪 boundary.").corpus_items.sole
    path = workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    [ "%", "_", "\\", "雪" ].each do |phrase|
      get path, params: { corpus_query: phrase }
      assert_response :success
      assert_select "#document-search [role=status]", text: /\A1 matching document/
      assert_select "select[name=evidence_item_id] option[value='#{document.id}']"
    end
    [ "' OR 1=1 --", "<script>foreign()</script>" ].each do |phrase|
      get path, params: { corpus_query: phrase }
      assert_response :success
      assert_select "select[name=evidence_item_id] option", count: 1
      assert_select "script", text: /foreign\(\)/, count: 0
    end
    [ "x" * 201, "bad\0phrase" ].each do |phrase|
      get path, params: { corpus_query: phrase }
      assert_response :unprocessable_content
      assert_select "#document-search-error[role=alert]", text: /200 characters and no null bytes/
      assert_includes response.body, %Q(value="#{ERB::Util.html_escape(phrase)}")
      assert_select "select[name=evidence_item_id] option", count: 1
    end
    assert_no_difference "ScenarioVersion.count" do
      patch path, params: { corpus_query: "x" * 201, version_id: @scenario.current_version_id,
        scenario: { known_facts: "broken", hidden_facts: "{}" } }
      assert_response :unprocessable_content
      assert_select "#document-search-error[role=alert]", text: /200 characters and no null bytes/
      assert_select "[role=alert]", text: /Facts, follow-ups and variant values must be valid JSON/
    end
    get path, params: { corpus_query: "  " + "雪" * 200 + "  " }
    assert_response :success
    trace = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Selected trace", kind: "traces", bytes: File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).corpus_items.sole
    get path, params: { corpus_query: "No document matches", trace_item_id: trace.id }
    assert_response :success
    assert_select "#document-search [role=status]", text: /\A0 matching documents/
    assert_select "#document-search input[name=trace_item_id][value='#{trace.id}']"
    assert_select "select[name=evidence_item_id] option[selected][value='#{trace.id}']"
    clear = css_select("#document-search a").find { |link| link.text == "Clear document search" }
    assert_equal trace.id.to_s, Rack::Utils.parse_query(URI(clear["href"]).query)["trace_item_id"]
    get clear["href"]
    assert_response :success
    assert_select "select[name=evidence_item_id] option[selected][value='#{trace.id}']"
  end

  test "document lookup filters debug binds and loads only picker metadata" do
    buffer = StringIO.new
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(buffer, level: Logger::DEBUG)
    statements = []
    capture = ->(event) { statements << event.payload if event.payload[:sql].include?("ILIKE") }
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
      get workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { corpus_query: "certificate expiry" }
      assert_response :success
      assert_select "select[name=evidence_item_id] option[value='#{@knowledge.id}']"
      assert_select "#document-search form[method=get] label[for=corpus_query]", text: "Company evidence phrase"
      assert_select "[id=corpus_query]", count: 1
    end
    assert_equal 2, statements.size
    statements.each do |payload|
      assert_not_includes payload[:sql], "certificate expiry"
      assert_includes payload[:binds].filter_map { |bind| bind.name if bind.respond_to?(:name) }, "corpus_query"
    end
    projection = statements.find { |payload| payload[:sql].include?("LIMIT") }.fetch(:sql).split(/\bFROM\b/, 2).first
    assert_equal %w[id title], projection.scan(/"corpus_items"\."([^"]+)"/).flatten
    refute_match(/"corpus_items"\.\*/, projection)
    assert_includes buffer.string, "[FILTERED]"
    assert_not_includes buffer.string, "certificate expiry"
  ensure
    ActiveRecord::Base.logger = original_logger
  end

  test "local search uses only current title situation and taxonomy literal substrings" do
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { title: "Historic aurora", situation: "Old definition", taxonomy_label: "Old category" })
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { title: "Current nebula", situation: "Diagnose the quasar boundary", taxonomy_label: "Pulsar diagnostics",
        known_facts: { private: "known-only-secret" }, hidden_facts: { private: "hidden-only-secret" },
        requirements: ScenarioVersion::REQUIREMENT_TYPES.index_with { [ "requirement-only-secret" ] } })
    other = (@scenarios - [ @scenario ]).sole
    other.revise!(membership: @membership, base_version_id: other.current_version_id,
      attributes: { title: "Unrelated case", situation: "Unrelated situation", taxonomy_label: "Unrelated category" })

    { "  nEbUlA  " => 1, "QUASAR" => 1, "pUlSaR" => 1, "aurora" => 0,
      "known-only-secret" => 0, "hidden-only-secret" => 0, "requirement-only-secret" => 0,
      "Request the certificate expiry date." => 0, @scenario.current_version.selection_reason => 0 }.each do |phrase, count|
      get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: phrase }
      assert_response :success
      assert_select ".workspace-card", count: count
      assert_select "#scenario-search [role=status]", text: /\A#{count} matching scenario/
      assert_select ".workspace-card a", text: "Current nebula", count: count
    end
    get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: "  " }
    assert_response :success
    assert_select ".workspace-card", count: 2
  end

  test "scenario search escapes literal wildcards and stays in its corpus and workspace" do
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { title: "Literal %_\\ boundary" })
    foreign = @workspace.corpora.create!(name: "Separate scenario corpus")
    foreign_item = CorpusIntake.call(corpus: foreign, membership: @membership, name: "Foreign evidence", kind: "document", bytes: "Foreign literal boundary.").corpus_items.sole
    foreign_scenario = foreign.scenarios.create!(workspace: @workspace, corpus_item: foreign_item)
    version = foreign_scenario.scenario_versions.create!(@scenario.current_version.attributes.slice(*ScenarioVersion::EDITABLE).merge(
      workspace: @workspace, corpus: foreign, created_by: @membership.user, number: 1, origin: "expert", selection_reason: "Foreign fixture", created_at: Time.current))
    version.scenario_evidence.create!(workspace: @workspace, corpus: foreign, corpus_item: foreign_item, kind: "knowledge", excerpt: foreign_item.content)
    foreign_scenario.update!(current_version: version)
    [ "%", "_", "\\", "%_\\" ].each do |phrase|
      get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: phrase }
      assert_response :success
      assert_select ".workspace-card", count: 1
      assert_select ".workspace-card a[href='#{workspace_corpus_scenario_path(@workspace, @corpus, @scenario)}']"
    end
    [ "' OR 1=1 --", "<script>foreign()</script>" ].each do |phrase|
      get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: phrase }
      assert_response :success
      assert_select ".workspace-card", count: 0
      assert_select("input[name=corpus_query]") { |inputs| assert_equal phrase, inputs.sole["value"] }
      assert_select "script", text: /foreign\(\)/, count: 0
    end
    get workspace_corpus_scenarios_path(workspaces(:beta_support), @corpus), params: { corpus_query: "boundary" }
    assert_response :not_found
    sign_in_as users(:outsider)
    get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: "boundary" }
    assert_response :not_found
  end

  test "viewer scenario search is private read only and preserves honest artifact labels" do
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: {},
      evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: @knowledge.content)
    approve_scenario
    other = (@scenarios - [ @scenario ]).sole
    other.review!(membership: @membership, version_id: other.current_version_id, decision: "reject", note: "Not an approved expectation")
    phrase = "certificate"
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioReview.count", "ScenarioProposal.count", "HumanLabel.count", "AuditEvent.count", "CorpusAnalysis.count" ] do
      assert_no_enqueued_jobs do
        get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: phrase }
        assert_response :success
        assert_select "#scenario-search form[method=get] input[type=search][name=corpus_query]", count: 1
        input = css_select("#scenario-search input[name=corpus_query]").sole
        assert_select "#scenario-search label[for='#{input['id']}']", text: "Scenario search phrase"
        submitters = css_select("#scenario-search input[type=submit], #scenario-search button[type=submit], #scenario-search button:not([type])")
        assert submitters.any? { |element| (element["value"] || element.text) == "Find scenarios" }
        assert_select ".workspace-card", count: 1
        assert_not_includes request.filtered_path, phrase
        assert_includes request.filtered_path, "corpus_query=[FILTERED]"
      end
    end
    sign_in_as users(:owner)
    get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: other.current_version.title }
    assert_select ".workspace-card", text: /reject/, count: 1
    other.review!(membership: @membership, version_id: other.current_version_id, decision: "merge", merge_into_id: @scenario.id)
    get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: other.current_version.title }
    assert_select ".workspace-card", text: /merged/, count: 1
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "SSO playbook", kind: "document", bytes: "Changed certificate policy.")
    get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: phrase }
    assert_select ".workspace-card", text: /source changed/, count: 1
    @snapshot.source.update!(expires_at: 1.minute.ago)
    get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: phrase }
    assert_select ".workspace-card", count: 0
    assert_select "#scenario-search [role=status]", text: /\A0 matching scenario/
  end

  test "invalid scenario phrases retain raw input and offer repair without list records" do
    get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: "雪" * 200 }
    assert_response :success
    [ "  " + "x" * 201 + "  ", "bad\0query" ].each do |phrase|
      get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: phrase }
      assert_response :unprocessable_content
      assert_select "#scenario-search [role=alert]", text: /200 characters and no null bytes/
      assert_select "input[name=corpus_query]", count: 1
      assert_includes response.body, %Q(value="#{ERB::Util.html_escape(phrase)}")
      assert_select ".workspace-card", count: 0
    end
    get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: "  " + "x" * 200 + "  " }
    assert_response :success
    assert_select ".workspace-card", count: 0
  end

  test "scenario search counts the whole filter and pages fifty ordered IDs with safe local recovery" do
    template = @scenario.current_version
    scenarios = 51.times.map do |index|
      scenario = @corpus.scenarios.create!(workspace: @workspace, corpus_item: @scenario.corpus_item)
      version = scenario.scenario_versions.create!(template.attributes.slice(*ScenarioVersion::EDITABLE).merge(
        title: "Paging constellation #{50 - index}", workspace: @workspace, corpus: @corpus, created_by: @membership.user,
        number: 1, origin: "expert", selection_reason: "Pagination fixture", created_at: Time.current))
      template.scenario_evidence.each do |evidence|
        version.scenario_evidence.create!(workspace: @workspace, corpus: @corpus, corpus_item: evidence.corpus_item, kind: evidence.kind, excerpt: evidence.excerpt)
      end
      scenario.update!(current_version: version)
      scenario
    end
    path = workspace_corpus_scenarios_path(@workspace, @corpus)
    get path, params: { corpus_query: "constellation", page: 0, protocol: "javascript", host: "alert(1)//", script_name: "//evil.example" }
    assert_response :success
    assert_select "#scenario-search [role=status]", text: /\A51 matching scenarios/
    assert_equal scenarios.first(50).map { |scenario| workspace_corpus_scenario_path(@workspace, @corpus, scenario) }, css_select(".workspace-card a").map { |link| link["href"] }
    next_link = css_select("a").find { |link| link.text == "Next records" }
    assert next_link
    uri = URI(next_link["href"])
    assert uri.relative?, uri.to_s
    assert_equal path, uri.path
    assert_equal "constellation", Rack::Utils.parse_query(uri.query)["corpus_query"]
    assert_equal "2", Rack::Utils.parse_query(uri.query)["page"]
    get next_link["href"]
    assert_response :success
    assert_select "#scenario-search [role=status]", text: /\A51 matching scenarios/
    assert_select ".workspace-card", count: 1
    assert_select ".workspace-card a[href='#{workspace_corpus_scenario_path(@workspace, @corpus, scenarios.last)}']"
    assert_select "a", text: "Next records", count: 0
    previous = css_select("a").find { |link| link.text == "Previous records" }
    assert previous
    uri = URI(previous["href"])
    assert uri.relative?, uri.to_s
    assert_equal path, uri.path
    assert_equal({ "corpus_query" => "constellation", "page" => "1" }, Rack::Utils.parse_query(uri.query).slice("corpus_query", "page"))
    clear = css_select("#scenario-search a").find { |link| link.text.match?(/Clear/) }
    assert clear, "Offer a clear-search link"
    get clear["href"]
    assert_response :success
    assert_select "#scenario-search [role=status]", text: /\A53 matching scenarios/
    assert_select ".workspace-card", count: 50
    assert_select("input[name=corpus_query]") { |inputs| assert inputs.sole["value"].blank? }
    get path, params: { corpus_query: "constellation", page: 10001 }
    assert_response :success
    assert_select ".workspace-card", count: 0
    assert_select "#scenario-search [role=status]", text: /\A51 matching scenarios/
    previous = css_select("a").find { |link| link.text == "Previous records" }
    assert previous
    assert_equal "9999", Rack::Utils.parse_query(URI(previous["href"]).query)["page"]
  end

  test "scenario search binds private phrases and preloads only current list metadata" do
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { title: "Private diagnostic nebula", situation: "Situation not needed for rendering" })
    buffer = StringIO.new
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(buffer, level: Logger::DEBUG)
    statements = []
    capture = ->(event) { statements << event.payload if event.payload[:sql].start_with?("SELECT") }
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
      get workspace_corpus_scenarios_path(@workspace, @corpus), params: { corpus_query: "diagnostic nebula" }
      assert_response :success
      assert_select ".workspace-card a", text: "Private diagnostic nebula", count: 1
    end
    searches = statements.select { |payload| payload[:sql].include?("ILIKE") }
    assert_not_empty searches
    searches.each do |payload|
      assert_not_includes payload[:sql], "diagnostic nebula"
      assert_includes payload[:binds].filter_map { |bind| bind.name if bind.respond_to?(:name) }, "corpus_query"
    end
    assert_includes buffer.string, "ILIKE"
    assert_includes buffer.string, "[FILTERED]"
    assert_not_includes buffer.string, "diagnostic nebula"
    projections = statements.map { |payload| payload[:sql].split(/\bFROM\b/, 2).first }.select { |sql| sql.include?('"scenario_versions"') }
    assert_not_empty projections
    assert projections.any? { |projection| projection.include?('"scenario_versions"."title"') }
    projections.each do |projection|
      refute_match(/"scenario_versions"\.\*/, projection)
      columns = projection.scan(/"scenario_versions"\."([^"]+)"/).flatten
      assert_empty columns - %w[id workspace_id corpus_id scenario_id number title importance]
    end
  ensure
    ActiveRecord::Base.logger = original_logger
  end

  test "read write errors preserve expert input and foreign routes are hidden" do
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    assert_response :success
    assert_select "h2", text: "Company evidence"
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { version_id: @scenario.current_version_id, scenario: { title: "Keep my edits", known_facts: "broken JSON", hidden_facts: "{}" } }
    assert_response :unprocessable_content
    assert_select "input[name='scenario[title]'][value='Keep my edits']"
    assert_select "textarea[name='scenario[known_facts]']", text: "broken JSON"
    assert_select "[role=alert]", text: /valid JSON/
    get workspace_corpus_scenario_path(workspaces(:beta_support), @corpus, @scenario)
    assert_response :not_found
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, version: 99)
    assert_response :not_found
  end

  test "trace entry selects exact evidence without copying input corrections or creating records" do
    trace = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).sole
    trace["input"]["known_facts"]["plan"] = "starter"
    item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "New production failure", kind: "traces", bytes: [ trace ].to_json).corpus_items.sole
    original = @scenario.current_version
    assert_no_difference [ "ScenarioVersion.count", "ScenarioReview.count", "AuditEvent.count", "HumanLabel.count", "ScenarioProposal.count" ] do
      get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, trace_item_id: item.id, anchor: "scenario-evidence")
      assert_response :success
      assert_select "details#scenario-evidence[open]"
      assert_select "select[name=evidence_item_id] option[selected][value='#{item.id}']"
      assert_select "input[name=trace_item_id][value='#{item.id}']"
      assert_select "textarea[name=excerpt]", text: ""
      assert_select "textarea[name='scenario[situation]']", text: original.situation
      assert_select "textarea[name='scenario[known_facts]']" do |fields|
        assert_equal original.known_facts, JSON.parse(fields.sole.text)
      end
      assert_select "textarea[name='scenario[outcomes]']", text: ""
    end
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { trace_item_id: item.id,
      version_id: original.id, evidence_item_id: item.id, evidence_kind: "expectation", excerpt: "Keep my invalid excerpt",
      scenario: { title: "Keep the expert edit", known_facts: "broken", hidden_facts: "{}" } }
    assert_response :unprocessable_content
    assert_select "details#scenario-evidence[open]"
    assert_select "select[name=evidence_item_id] option[selected][value='#{item.id}']"
    assert_select "textarea[name=excerpt]", text: "Keep my invalid excerpt"
    assert_select "input[name='scenario[title]'][value='Keep the expert edit']"
    assert_equal original.id, @scenario.reload.current_version_id
    assert_no_difference "ScenarioVersion.count" do
      patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { trace_item_id: item.id,
        version_id: original.id, evidence_item_id: item.id, evidence_kind: "expectation", excerpt: "Keep my invalid excerpt",
        scenario: { known_facts: original.known_facts.to_json, hidden_facts: "{}" } }
      assert_response :unprocessable_content
      assert_select "#evidence-error[role=alert]", text: /Read the exact source record, paste a matching excerpt and save again/
      assert_select "textarea[name=excerpt][aria-invalid=true][aria-describedby=evidence-error]", text: "Keep my invalid excerpt"
    end
  end

  test "trace entry rejects foreign corpus expired wrong-kind and non-scalar references" do
    trace = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).sole
    foreign_corpus = @workspace.corpora.create!(name: "Other isolated dataset")
    foreign = CorpusIntake.call(corpus: foreign_corpus, membership: @membership, name: "Other failure", kind: "traces", bytes: [ trace ].to_json).corpus_items.sole
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, trace_item_id: foreign.id)
    assert_response :not_found
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, trace_item_id: @knowledge.id)
    assert_response :not_found
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, trace_item_id: [ @knowledge.id ])
    assert_response :bad_request
    item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Expired failure", kind: "traces", bytes: [ trace ].to_json).corpus_items.sole
    item.source_snapshot.source.update!(expires_at: 1.minute.ago)
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, trace_item_id: item.id)
    assert_response :not_found
  end

  test "viewer cannot revise review mine or create variants and expiry hides index titles" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    assert_response :success
    assert_select "input[type=submit]", count: 0
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
    assert_response :forbidden
    post review_workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
    assert_response :forbidden
    post variant_workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
    assert_response :forbidden
    post workspace_corpus_scenarios_path(@workspace, @corpus), params: { analysis_id: @analysis.id }
    assert_response :forbidden
    travel 366.days do
      sign_in_as users(:teammate)
      get workspace_corpus_scenarios_path(@workspace, @corpus)
      assert_response :success
      assert_select ".workspace-card", count: 0
      get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
      assert_response :not_found
    end
  end

  test "malformed follow up shape retains the expert JSON and repair details" do
    plan = '[{"after_assistant_contains":"expiry","message":"date","unexpected":true}]'
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { version_id: @scenario.current_version_id,
      scenario: { known_facts: "{}", hidden_facts: "{}", follow_ups: plan } }
    assert_response :unprocessable_content
    assert_select "textarea[name='scenario[follow_ups]']", text: plan
    assert_select "[role=alert]", text: /Follow ups.*exactly after_assistant_contains/
  end

  test "an omitted plan preserves existing follow-ups while an explicit empty array removes them" do
    plan = [ { "after_assistant_contains" => "expiry", "message" => "It expired yesterday." } ]
    version = @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { follow_ups: plan })
    values = { title: "Changed starting title", known_facts: version.known_facts.to_json, hidden_facts: version.hidden_facts.to_json }
      .merge(version.requirements.transform_values { |statements| statements.join("\n") })
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { version_id: version.id, scenario: values }
    assert_response :see_other
    assert_equal plan, @scenario.reload.current_version.follow_ups
    assert_equal plan, version.reload.follow_ups
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { version_id: @scenario.current_version_id, scenario: values.merge(follow_ups: "[]") }
    assert_response :see_other
    assert_empty @scenario.reload.current_version.follow_ups
    assert_equal plan, version.reload.follow_ups
  end
end
