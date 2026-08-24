class PublicWebResearch
  class Error < StandardError; end
  class PolicyDenied < Error; end

  EMAIL = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
  PHONE = /(?<!\w)(?:\+?\d[\d .()-]{7,}\d)(?!\w)/
  SECRET = /\b(?:bearer\s+\S+|(?:api[_-]?key|password|secret|token)\s*[:=]\s*\S+)/i

  def self.perform!(workspace:, membership:, task:, query:, request_key:, client: nil)
    new(workspace:, membership:).perform!(task:, query:, request_key:, client:)
  end

  def initialize(workspace:, membership:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
  end

  def perform!(task:, query:, request_key:, client:)
    authorize!
    task = @workspace.crew_tasks.find(task.id)
    unless task.assigned_agent_profile_version.allowed_tools.include?("public_web_search")
      raise PolicyDenied, "This specialist is not allowed to search the public web."
    end
    safe_query, decision = minimize(query)
    search = claim!(task:, query: safe_query, request_key:, policy_decision: decision)
    return search if search.completed? || search.failed?

    client ||= RunnerClient.new
    response = client.web_search!(
      workspace_key: @workspace.runner_key, request_key: search.request_key, query: search.query, max_results: 5
    )
    complete!(search, response)
  rescue RunnerClient::AmbiguousResult
    raise
  rescue RunnerClient::Error => error
    fail!(search, error) if search&.persisted? && search.searching?
    raise
  end

  private
    def authorize!
      raise Current::RoleAccessDenied unless @membership.can_write?
    end

    def minimize(query)
      value = query.to_s.strip.squish
      raise Error, "Write a search query between 2 and 500 characters." unless value.bytesize.between?(2, 500)

      safe = value.gsub(EMAIL, "[redacted email]")
        .gsub(PHONE) { |candidate| candidate.count("0-9") >= 9 ? "[redacted phone]" : candidate }
        .gsub(SECRET, "[redacted secret]")
      raise Error, "The query contains no searchable public terms after redaction." unless safe.match?(/[A-Za-z0-9]{2}/)

      [ safe, safe == value ? "allowed" : "redacted" ]
    end

    def claim!(task:, query:, request_key:, policy_decision:)
      PublicWebSearch.transaction do
        task.lock!
        existing = @workspace.public_web_searches.find_by(request_key: request_key.to_s)
        if existing
          unless existing.crew_task_id == task.id && existing.query == query
            raise Error, "Search request key belongs to another query."
          end
          if existing.searching?
            AuditEvent.record!(
              action: "public_web.search_retried", source: :web, workspace: @workspace,
              actor: @membership.user, subject: existing
            )
          end
          return existing
        end
        search = @workspace.public_web_searches.create!(
          crew_task: task, request_key: request_key.to_s, query:, policy_decision:,
          requested_by_membership: @membership, requested_by_user: @membership.user
        )
        AuditEvent.record!(
          action: "public_web.search_requested", source: :web, workspace: @workspace,
          actor: @membership.user, subject: search,
          metadata: { "policy_decision" => policy_decision }
        )
        search
      end
    rescue ActiveRecord::RecordInvalid => error
      raise Error, error.record.errors.full_messages.to_sentence
    end

    def complete!(search, response)
      PublicWebSearch.transaction do
        search.lock!
        return search unless search.searching?

        retrieved_at = Time.iso8601(response.fetch("retrieved_at"))
        search.update!(
          status: "completed", provider_key: response.fetch("provider_key"),
          policy_decision: response.fetch("policy_decision") == "allowed" ? search.policy_decision : response.fetch("policy_decision"),
          cost_units: response.fetch("cost_units"), retrieved_at:
        )
        response.fetch("results").each do |result|
          canonical = {
            "title" => result.fetch("title"), "url" => result.fetch("url"),
            "excerpt" => result.fetch("excerpt"), "published_at" => result["published_at"]
          }
          search.results.create!(
            workspace: @workspace, rank: result.fetch("rank"), title: canonical.fetch("title"),
            url: canonical.fetch("url"), excerpt: canonical.fetch("excerpt"),
            published_at: canonical["published_at"] && Time.iso8601(canonical["published_at"]),
            retrieved_at:, content_digest: Digest::SHA256.hexdigest(JSON.generate(canonical))
          )
        end
        AuditEvent.record!(
          action: "public_web.search_completed", source: :web, workspace: @workspace,
          actor: @membership.user, subject: search,
          metadata: { "provider" => search.provider_key, "result_count" => search.results.size, "cost_units" => search.cost_units }
        )
        search
      end
    rescue ActiveRecord::RecordInvalid => error
      raise Error, error.record.errors.full_messages.to_sentence
    end

    def fail!(search, error)
      search.with_lock do
        return unless search.searching?

        search.update!(status: "failed", failure_code: error.class.name.demodulize.underscore.first(100))
        AuditEvent.record!(
          action: "public_web.search_failed", source: :web, workspace: @workspace,
          actor: @membership.user, subject: search,
          metadata: { "failure_code" => search.failure_code }
        )
      end
    end
end
