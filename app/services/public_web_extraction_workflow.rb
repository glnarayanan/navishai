class PublicWebExtractionWorkflow
  class Error < StandardError; end
  class PolicyDenied < Error; end

  def self.perform!(workspace:, membership:, task:, result:, request_key:, fetcher: GuardedWebFetcher.new)
    new(workspace:, membership:, fetcher:).perform!(task:, result:, request_key:)
  end

  def initialize(workspace:, membership:, fetcher:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
    @fetcher = fetcher
  end

  def perform!(task:, result:, request_key:)
    authorize!
    task = @workspace.crew_tasks.find(task.id)
    result = result_for!(task, result)
    unless task.assigned_agent_profile_version.allowed_tools.include?("web_extract")
      raise PolicyDenied, "This specialist is not allowed to extract public web pages."
    end

    extraction = claim!(task:, result:, request_key:)
    return extraction if extraction.completed? || extraction.failed?

    fetched = @fetcher.fetch(extraction.source_url)
    complete!(extraction, fetched)
  rescue GuardedWebFetcher::Error
    fail!(extraction, "secure_fetch_failed") if extraction&.persisted? && extraction.extracting?
    extraction
  end

  private
    def authorize!
      raise Current::RoleAccessDenied unless @membership.can_write?
    end

    def result_for!(task, result)
      @workspace.public_web_search_results.joins(:public_web_search)
        .where(public_web_searches: { crew_task_id: task.id, status: "completed" }).find(result.id)
    end

    def claim!(task:, result:, request_key:)
      PublicWebExtraction.transaction do
        task.lock!
        result.lock!
        existing = @workspace.public_web_extractions.find_by(request_key: request_key.to_s)
        if existing
          unless existing.public_web_search_result_id == result.id && existing.source_url == result.url
            raise Error, "Extraction request key belongs to another result."
          end
          if existing.extracting?
            AuditEvent.record!(action: "public_web.extraction_retried", source: :web, workspace: @workspace,
              actor: @membership.user, subject: existing)
          end
          return existing
        end

        extraction = @workspace.public_web_extractions.create!(
          public_web_search_result: result, request_key: request_key.to_s, source_url: result.url,
          requested_by_membership: @membership, requested_by_user: @membership.user
        )
        AuditEvent.record!(action: "public_web.extraction_requested", source: :web, workspace: @workspace,
          actor: @membership.user, subject: extraction)
        extraction
      end
    rescue ActiveRecord::RecordInvalid => error
      raise Error, error.record.errors.full_messages.to_sentence
    end

    def complete!(extraction, fetched)
      extraction.with_lock do
        return extraction unless extraction.extracting?

        extraction.update!(
          status: "completed", final_url: fetched.url, content: fetched.content,
          content_digest: Digest::SHA256.hexdigest(fetched.content), retrieved_at: fetched.retrieved_at,
          source_updated_at: fetched.source_updated_at
        )
        AuditEvent.record!(action: "public_web.extraction_completed", source: :web, workspace: @workspace,
          actor: @membership.user, subject: extraction)
        extraction
      end
    end

    def fail!(extraction, code)
      extraction.with_lock do
        return extraction unless extraction.extracting?

        extraction.update!(status: "failed", failure_code: code)
        AuditEvent.record!(action: "public_web.extraction_failed", source: :web, workspace: @workspace,
          actor: @membership.user, subject: extraction, metadata: { "failure_code" => code })
        extraction
      end
    end
end
