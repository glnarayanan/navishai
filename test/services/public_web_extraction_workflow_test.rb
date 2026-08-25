require "test_helper"

class PublicWebExtractionWorkflowTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    @task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile:,
      title: "Extract public evidence", input_context: "Use public evidence.", expected_output: "Return cited facts."
    )
    @result = completed_result(@task)
  end

  test "stores an immutable sanitized snapshot with an attributable audit trail" do
    fetched_at = Time.zone.parse("2026-08-24 12:00 UTC")
    updated_at = Time.zone.parse("2026-08-23 09:00 UTC")
    captured_url = nil
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |url|
      captured_url = url
      GuardedWebFetcher::Result.new(
        content: "Guarded public evidence.", url: "https://status.example.com/final",
        retrieved_at: fetched_at, source_updated_at: updated_at
      )
    end

    extraction = PublicWebExtractionWorkflow.perform!(
      workspace: @workspace, membership: @owner, task: @task, result: @result,
      request_key: "extract:one", fetcher:
    )

    assert extraction.completed?
    assert_equal @result.url, captured_url
    assert_equal @result.url, extraction.source_url
    assert_equal "https://status.example.com/final", extraction.final_url
    assert_equal Digest::SHA256.hexdigest("Guarded public evidence."), extraction.content_digest
    assert_equal fetched_at, extraction.retrieved_at
    assert_equal updated_at, extraction.source_updated_at
    assert_equal %w[public_web.extraction_requested public_web.extraction_completed],
      AuditEvent.where(subject_type: "PublicWebExtraction", subject_id: extraction.id).order(:id).pluck(:action)
    assert_raises(ActiveRecord::StatementInvalid) do
      PublicWebExtraction.transaction(requires_new: true) { PublicWebExtraction.where(id: extraction.id).update_all(content: "changed") }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      PublicWebExtraction.transaction(requires_new: true) { PublicWebExtraction.where(id: extraction.id).delete_all }
    end
  end

  test "retries an interrupted request key and makes guarded failures terminal" do
    interrupted = Object.new
    interrupted.define_singleton_method(:fetch) { |_| raise "process stopped" }
    assert_raises(RuntimeError) do
      PublicWebExtractionWorkflow.perform!(
        workspace: @workspace, membership: @owner, task: @task, result: @result,
        request_key: "extract:interrupted", fetcher: interrupted
      )
    end
    claim = @workspace.public_web_extractions.find_by!(request_key: "extract:interrupted")
    assert claim.extracting?

    extraction = PublicWebExtractionWorkflow.perform!(
      workspace: @workspace, membership: @owner, task: @task, result: @result,
      request_key: claim.request_key, fetcher: successful_fetcher
    )
    assert extraction.completed?
    assert_equal 1, AuditEvent.where(action: "public_web.extraction_requested", subject_id: extraction.id).count
    assert_equal 1, AuditEvent.where(action: "public_web.extraction_retried", subject_id: extraction.id).count

    blocked = Object.new
    blocked.define_singleton_method(:fetch) { |_| raise GuardedWebFetcher::Error, "blocked" }
    failed = PublicWebExtractionWorkflow.perform!(
      workspace: @workspace, membership: @owner, task: @task, result: @result,
      request_key: "extract:failed", fetcher: blocked
    )
    assert failed.failed?
    assert_equal "secure_fetch_failed", failed.failure_code
  end

  test "policy tenancy task and request-key boundaries fail closed" do
    coordinator = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    denied_task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: coordinator,
      title: "Coordinate only", input_context: "Use case facts.", expected_output: "Return a plan."
    )
    denied_result = completed_result(denied_task, key: "search:denied")
    assert_raises(PublicWebExtractionWorkflow::PolicyDenied) do
      PublicWebExtractionWorkflow.perform!(
        workspace: @workspace, membership: @owner, task: denied_task, result: denied_result,
        request_key: "extract:denied", fetcher: successful_fetcher
      )
    end

    PublicWebExtractionWorkflow.perform!(
      workspace: @workspace, membership: @owner, task: @task, result: @result,
      request_key: "extract:bound", fetcher: successful_fetcher
    )
    assert_raises(PublicWebExtractionWorkflow::Error) do
      PublicWebExtractionWorkflow.perform!(
        workspace: @workspace, membership: @owner, task: denied_task, result: denied_result,
        request_key: "extract:bound", fetcher: successful_fetcher
      )
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      PublicWebExtractionWorkflow.perform!(
        workspace: workspaces(:beta_support), membership: memberships(:outsider_beta), task: @task, result: @result,
        request_key: "extract:foreign", fetcher: successful_fetcher
      )
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      PublicWebExtractionWorkflow.perform!(
        workspace: @workspace, membership: @owner, task: denied_task, result: @result,
        request_key: "extract:wrong-task", fetcher: successful_fetcher
      )
    end
  end

  private
    def completed_result(task, key: "search:extract")
      search = @workspace.public_web_searches.create!(
        crew_task: task, request_key: key, query: "public incident", status: "completed",
        provider_key: "searxng", retrieved_at: Time.current,
        requested_by_membership: @owner, requested_by_user: @owner.user
      )
      search.results.create!(
        workspace: @workspace, rank: 1, title: "Incident report", url: "https://status.example.com/incident",
        excerpt: "Public excerpt.", retrieved_at: Time.current, content_digest: "a" * 64
      )
    end

    def successful_fetcher
      Object.new.tap do |fetcher|
        fetcher.define_singleton_method(:fetch) do |_|
          GuardedWebFetcher::Result.new(
            content: "Evidence.", url: "https://status.example.com/incident",
            retrieved_at: Time.current, source_updated_at: nil
          )
        end
      end
    end
end
