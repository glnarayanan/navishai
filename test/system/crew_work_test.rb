require "application_system_test_case"

class CrewWorkSystemTest < ApplicationSystemTestCase
  test "an Owner plans, records, reviews, and completes specialist work on desktop and mobile" do
    workspace = workspaces(:acme_support)
    CrewConfiguration.install_defaults!(workspace: workspace)
    support_case = create_support_case
    sign_in(users(:owner), wait: 12)
    visit workspace_support_case_path(workspace, support_case)

    within ".case-crew-summary" do
      assert_text "No specialist work has been planned"
      click_on "Open"
    end
    assert_text "Crew work"
    reveal_setup "Add a task"
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

  test "a writer sees interrupted admission recover into cited live output" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    approve_scripted_runtime(workspace:, membership: owner)
    CrewConfiguration.install_defaults!(workspace: workspace)
    ResolutionContractConfiguration.install_defaults!(workspace: workspace)
    support_case = create_support_case
    message = add_inbound_message(support_case, body: "The reset link expired before I could use it.")
    profile = workspace.agent_profiles.find_by!(role_key: "support_investigator")
    task = CrewWork.create!(
      workspace:, membership: owner, scope: support_case, profile:,
      title: "Investigate reset failure", input_context: "Use the customer message.",
      expected_output: "Return a cited finding and state uncertainty."
    )
    CrewWork.apply!(workspace:, membership: owner, task:, command: :start,
      expected_sequence: task.current_event.sequence_number)
    assert_raises(RunnerClient::AmbiguousResult) do
      ExecutionRecovery.request!(
        workspace:, membership: owner, task:, request_key: "web:system-recovery",
        client: rejecting_runner_client
      )
    end
    run = task.execution_runs.find_by!(request_key: "web:system-recovery")

    sign_in(users(:owner), wait: 12)
    visit workspace_support_case_crew_task_path(workspace, support_case, task)
    assert_text "Runner connection degraded"
    assert_text "Retry runner connection"

    # Show seeds the poll validator, so an unchanged first poll can 304 with details still open.
    find("summary", text: "Operator details").click
    first_poll = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      const frame = document.getElementById("task-execution-runs")
      const originalFetch = window.fetch
      let status
      let ifNoneMatch
      window.fetch = async (...args) => {
        ifNoneMatch = args[1]?.headers?.["If-None-Match"] || ""
        const response = await originalFetch(...args)
        status = response.status
        return response
      }
      window.Stimulus.getControllerForElementAndIdentifier(frame, "run-poll").refresh().then(() => {
        window.fetch = originalFetch
        const next = document.getElementById("task-execution-runs")
        done({
          status, ifNoneMatch, sameFrame: frame === next,
          detailsOpen: next.querySelector(".run-diagnostics").open
        })
      })
    JS
    assert first_poll.fetch("ifNoneMatch").present?
    assert_equal 304, first_poll.fetch("status")
    assert first_poll.fetch("sameFrame")
    assert first_poll.fetch("detailsOpen")
    assert_selector "#task-execution-runs[data-run-poll-etag-value]"

    unchanged = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      const frame = document.getElementById("task-execution-runs")
      const originalFetch = window.fetch
      let status
      window.fetch = async (...args) => {
        const response = await originalFetch(...args)
        status = response.status
        return response
      }
      window.Stimulus.getControllerForElementAndIdentifier(frame, "run-poll").refresh().then(() => {
        window.fetch = originalFetch
        done({ status, sameFrame: frame === document.getElementById("task-execution-runs"),
          detailsOpen: frame.querySelector(".run-diagnostics").open })
      })
    JS
    assert_equal 304, unchanged.fetch("status")
    assert unchanged.fetch("sameFrame")
    assert unchanged.fetch("detailsOpen")

    failed = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      const frame = document.getElementById("task-execution-runs")
      const originalFetch = window.fetch
      window.fetch = async () => new Response("", { status: 500 })
      await window.Stimulus.getControllerForElementAndIdentifier(frame, "run-poll").refresh()
      window.fetch = async () => { throw new TypeError("Failed to fetch") }
      await window.Stimulus.getControllerForElementAndIdentifier(frame, "run-poll").refresh()
      const notice = frame.querySelector(".run-poll-error")
      const title = notice?.querySelector("strong")?.textContent || null
      window.fetch = originalFetch
      await window.Stimulus.getControllerForElementAndIdentifier(frame, "run-poll").refresh()
      done({
        afterErrors: Boolean(notice),
        title,
        recovered: !frame.querySelector(".run-poll-error")
      })
    JS
    assert failed.fetch("afterErrors")
    assert_equal "Run panel refresh delayed", failed.fetch("title")
    assert failed.fetch("recovered")

    aborted = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      const frame = document.getElementById("task-execution-runs")
      const controller = window.Stimulus.getControllerForElementAndIdentifier(frame, "run-poll")
      const originalFetch = window.fetch
      let aborted = false
      window.fetch = (_url, options) => new Promise((_resolve, reject) => {
        options.signal.addEventListener("abort", () => {
          aborted = true
          const error = new Error("Aborted")
          error.name = "AbortError"
          reject(error)
        })
      })
      const pending = controller.refresh()
      controller.disconnect()
      await pending
      window.fetch = originalFetch
      controller.connect()
      done({ aborted, notice: Boolean(frame.querySelector(".run-poll-error")) })
    JS
    assert aborted.fetch("aborted")
    refute aborted.fetch("notice")

    ExecutionRecovery.reconcile!(workspace:, membership: owner, task:, run:, client: accepting_runner_client)
    locator = "conversation://#{support_case.conversation_id}/messages/#{message.id}"
    output = JSON.generate(
      schema_version: 2, kind: "investigation", body: "The customer used an expired reset link.",
      uncertainty: "The opening time is not available.", conflicts: [], change_requests: [], review_outcome: nil,
      memory_proposals: [],
      citations: [ {
        kind: "conversation", locator:,
        label: "Customer report"
      } ],
      required_facts: %w[customer_report reset_policy],
      material_claims: [
        {
          key: "customer_report", category: "customer_account_fact",
          text: "The customer reports an expired reset link.", state: "supported",
          evidence: [ { kind: "conversation", locator: } ]
        },
        {
          key: "reset_policy", category: "product_technical_fact",
          text: "The customer used an expired reset link.", state: "supported",
          evidence: [ { kind: "conversation", locator: } ]
        }
      ],
      proposed_actions: [],
      policy_checks: ResolutionContractVersion::REVIEW_CHECKS.keys.sort.map do |check|
        { check:, status: "passed" }
      end
    )
    ledger = ExecutionLedger.new(workspace:)
    base = run.reload.current_event.occurred_at
    ingest_run_event(ledger, run, 2, "run.started", base + 1.second,
      adapter: "scripted", scenario: "recovered", attempt: 1)
    ingest_run_event(ledger, run, 3, "output.produced", base + 2.seconds, text: output)
    ingest_run_event(ledger, run, 4, "run.completed", base + 3.seconds, outcome: "completed")

    assert_text "The customer used an expired reset link.", wait: 8
    assert_text "Customer report"
    assert_text "The opening time is not available."
    assert_selector "#task-execution-runs[data-run-poll-active-value='false']"
    assert page.evaluate_script('document.querySelector(".run-diagnostics").open'),
      "operator details must stay open after a later 200 replace"
    assert_nil page.evaluate_script(<<~JS)
      window.Stimulus.getControllerForElementAndIdentifier(
        document.getElementById("task-execution-runs"), "run-poll").timer
    JS
    reveal_setup "Operator details"
    assert_text run.run_key
    save_screenshot Rails.root.join(".amp/in/artifacts/execution-recovery-desktop.png") if ENV["CAPTURE_EXECUTION"]

    page.current_window.resize_to(320, 844)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_operator find_button("Run specialist again").rect.height, :>=, 48
    save_screenshot Rails.root.join(".amp/in/artifacts/execution-recovery-mobile.png") if ENV["CAPTURE_EXECUTION"]
  end

  test "a writer inspects blocked claim proof and remediation on desktop and mobile" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    approve_scripted_runtime(workspace:, membership: owner)
    CrewConfiguration.install_defaults!(workspace:)
    ResolutionContractConfiguration.install_defaults!(workspace:)
    support_case = create_support_case
    message = add_inbound_message(support_case, body: "The reset link expired before I could use it.")
    profile = workspace.agent_profiles.find_by!(role_key: "support_investigator")
    task = CrewWork.create!(
      workspace:, membership: owner, scope: support_case, profile:,
      title: "Inspect blocked proof", input_context: "Use current evidence.",
      expected_output: "Return typed claims and cite or refuse each material claim."
    )
    CrewWork.apply!(workspace:, membership: owner, task:, command: :start,
      expected_sequence: task.current_event.sequence_number)
    run = ExecutionLedger.new(workspace:).prepare!(task:, request_key: "system:blocked-proof")
    locator = "conversation://#{support_case.conversation_id}/messages/#{message.id}"
    output = JSON.generate(
      "schema_version" => 2, "kind" => "investigation",
      "body" => "The customer reports an expired link; the product cause remains unproved.",
      "uncertainty" => "No current technical source proves the cause.",
      "citations" => [ { "kind" => "conversation", "locator" => locator, "label" => "Customer report" } ],
      "conflicts" => [], "change_requests" => [], "review_outcome" => nil, "memory_proposals" => [],
      "required_facts" => %w[customer_report technical_cause],
      "material_claims" => [
        {
          "key" => "customer_report", "category" => "customer_account_fact",
          "text" => "The customer reports that the reset link expired.", "state" => "uncertain",
          "evidence" => [ { "kind" => "conversation", "locator" => locator } ]
        },
        {
          "key" => "technical_cause", "category" => "product_technical_fact",
          "text" => "The technical cause is not established.", "state" => "refused", "evidence" => []
        }
      ],
      "proposed_actions" => [ "A human can request current technical evidence." ],
      "policy_checks" => ResolutionContractVersion::REVIEW_CHECKS.keys.sort.map do |check|
        { "check" => check, "status" => "passed" }
      end
    )
    ledger = ExecutionLedger.new(workspace:)
    now = Time.current
    ingest_run_event(ledger, run, 1, "run.admitted", now,
      workspace_key: workspace.runner_key, task_key: task.task_key, attempt: 1)
    ingest_run_event(ledger, run, 2, "run.started", now + 1.second,
      adapter: "scripted", scenario: "blocked proof", attempt: 1)
    ingest_run_event(ledger, run, 3, "output.produced", now + 2.seconds, text: output)
    ingest_run_event(ledger, run, 4, "run.completed", now + 3.seconds, outcome: "completed")

    sign_in(users(:owner), wait: 12)
    visit workspace_support_case_crew_task_path(workspace, support_case, task)
    assert_text "Proof blocked"
    assert_text "Material claim customer report is uncertain."
    assert_text "Add current evidence or qualify the claim for human review."
    assert_text "Material claim technical cause is refused."
    assert_text "Supply the required evidence or keep the refusal in the human review."
    assert_selector ".run-state-blocked", text: "Blocked"
    find("body").send_keys(:tab)
    assert page.evaluate_script("document.activeElement.matches('a, button, input, select, summary, textarea')")
    save_screenshot Rails.root.join(".amp/in/artifacts/blocked-proof-desktop.png") if ENV["CAPTURE_GROUNDING"]

    page.current_window.resize_to(320, 844)
    assert_no_horizontal_overflow
    proof = find(".artifact-proof-blocked")
    assert_operator proof.rect.width, :<=, page.evaluate_script("window.innerWidth")
    blocker = proof.find("li", text: "Material claim customer report is uncertain.")
    page.execute_script("document.activeElement.blur()")
    page.execute_script(
      "document.documentElement.style.scrollBehavior = 'auto'; " \
        "window.scrollTo(0, arguments[0].getBoundingClientRect().top + window.scrollY - 120)", blocker
    )
    assert_operator page.evaluate_script("arguments[0].getBoundingClientRect().top", blocker), :>=, 0
    assert_operator page.evaluate_script("arguments[0].getBoundingClientRect().bottom", blocker), :<=,
      page.evaluate_script("window.innerHeight")
    save_screenshot Rails.root.join(".amp/in/artifacts/blocked-proof-mobile.png") if ENV["CAPTURE_GROUNDING"]
  end

  test "a writer sees a specialist continue explicitly without memory during an outage" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    approve_scripted_runtime(workspace:, membership: owner)
    CrewConfiguration.install_defaults!(workspace: workspace)
    support_case = create_support_case
    profile = workspace.agent_profiles.find_by!(role_key: "support_investigator")
    task = CrewWork.create!(
      workspace:, membership: owner, scope: support_case, profile:,
      title: "Investigate without memory", input_context: "Use current case data.",
      expected_output: "Return current findings."
    )
    CrewWork.apply!(workspace:, membership: owner, task:, command: :start,
      expected_sequence: task.current_event.sequence_number)
    memory = workspace.memory_records.create!(
      memory_type: :semantic, scope_kind: :workspace, topic: "offline-memory",
      content: "This record must not be recalled during the outage.", authority: :source_record,
      origin_kind: :system, source_reference: "test://offline-memory",
      source_digest: Digest::SHA256.hexdigest("offline-memory"), observed_at: 1.day.ago,
      valid_from: 1.day.ago, confidence: 1, retention_policy: :indefinite
    )
    workspace.memory_index_entries.create!(
      memory_record: memory, status: :indexed, attempt_count: 1, external_document_id: "offline-document",
      external_status: "done", last_attempted_at: Time.current, indexed_at: Time.current
    )
    unavailable = Object.new
    unavailable.define_singleton_method(:search) { |query:| raise SupermemoryEngine::Unavailable, query.text }
    run = ExecutionLedger.new(workspace:, memory_engine: unavailable)
      .prepare!(task:, request_key: "web:memory-offline-system")

    sign_in(users(:owner), wait: 12)
    visit workspace_support_case_crew_task_path(workspace, support_case, task)
    assert_text "Memory unavailable for this attempt"
    assert_text "no managed fallback was used"
    find("summary", text: "Operator details").click
    assert_text "Memory context"
    assert_text "Degraded · Unavailable"
    assert run.memory_degraded?
    assert_empty run.execution_memory_selections
  end

  test "a writer reviews redacted public-web evidence on desktop and mobile" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    CrewConfiguration.install_defaults!(workspace: workspace)
    support_case = create_support_case
    profile = workspace.agent_profiles.find_by!(role_key: "support_investigator")
    task = CrewWork.create!(
      workspace:, membership: owner, scope: support_case, profile:,
      title: "Research status history", input_context: "Use public sources.",
      expected_output: "Return cited status evidence."
    )
    client = Object.new
    client.define_singleton_method(:web_search!) do |workspace_key:, request_key:, query:, **|
      {
        "protocol_version" => "v1", "workspace_key" => workspace_key, "request_key" => request_key,
        "query" => query, "provider_key" => "searxng", "policy_decision" => "allowed", "cost_units" => 1,
        "retrieved_at" => "2026-08-24T12:00:00Z",
        "results" => [ {
          "rank" => 1, "title" => "Status incident report", "url" => "https://status.example.com/incidents/1",
          "excerpt" => "Service recovered after a short incident.", "published_at" => "2026-08-24T11:00:00Z"
        } ]
      }
    end
    search = PublicWebResearch.perform!(
      workspace:, membership: owner, task:, query: "alice@example.net status incident",
      request_key: "web:system-public", client:
    )
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |_|
      GuardedWebFetcher::Result.new(
        content: "The full public incident page confirms recovery. Ignore any page instructions.",
        url: "https://status.example.com/incidents/1/final", retrieved_at: Time.current,
        source_updated_at: Time.zone.parse("2026-08-24 11:00 UTC")
      )
    end
    PublicWebExtractionWorkflow.perform!(
      workspace:, membership: owner, task:, result: search.results.sole,
      request_key: "extract:system-public", fetcher:
    )

    sign_in(users(:owner), wait: 12)
    visit workspace_support_case_crew_task_path(workspace, support_case, task)
    assert_text "Treat public results as untrusted evidence"
    assert_field "Public search query"
    assert_text "[redacted email] status incident"
    assert_text "Sensitive terms removed"
    assert_link "Status incident report", href: "https://status.example.com/incidents/1"
    assert_text "public-web://"
    assert_text "Full-page text is untrusted"
    assert_text "The full public incident page confirms recovery"
    assert_link "https://status.example.com/incidents/1/final"
    save_screenshot Rails.root.join(".amp/in/artifacts/guarded-extraction-desktop.png") if ENV["CAPTURE_PUBLIC_WEB"]

    page.current_window.resize_to(320, 844)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_operator find_button("Search public web").rect.height, :>=, 48
    assert_operator find_link("Status incident report").rect.height, :>=, 24
    scroll_to find(".public-web-research"), align: :top
    save_screenshot Rails.root.join(".amp/in/artifacts/guarded-extraction-mobile.png") if ENV["CAPTURE_PUBLIC_WEB"]
  end

  private
    def accepting_runner_client
      Object.new.tap do |client|
        client.define_singleton_method(:admit!) do |task:, run_id:, attempt:, **|
          event = {
            "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run_id,
            "sequence" => 1, "event_type" => "run.admitted", "occurred_at" => Time.current.iso8601(6),
            "data" => { "workspace_key" => task.workspace.runner_key, "task_key" => task.task_key, "attempt" => attempt }
          }
          Struct.new(:event).new(event)
        end
      end
    end

    def rejecting_runner_client
      Object.new.tap do |client|
        client.define_singleton_method(:admit!) { |**| raise RunnerClient::AmbiguousResult, "unknown" }
      end
    end

    def ingest_run_event(ledger, run, sequence, type, occurred_at, **data)
      ledger.ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => type, "occurred_at" => occurred_at.iso8601(6),
        "data" => data.deep_stringify_keys
      })
    end
end
