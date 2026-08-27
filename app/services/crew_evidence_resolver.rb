class CrewEvidenceResolver
  Result = Data.define(:snapshot) do
    def available?
      snapshot.fetch("status") == "available"
    end
  end

  STATUSES = %w[available stale expired deleted unavailable conflicted not_yet_valid].freeze

  def initialize(workspace:, task:, run:, at: Time.current)
    @workspace = workspace
    @task = task
    @run = run
    @at = at
  end

  def resolve(kind:, locator:, freshness_days:)
    kind = kind.to_s
    locator = locator.to_s
    source = source_for(kind, locator)
    status = source.fetch(:status, "available")
    observed_at = source[:observed_at]
    valid_from = source[:valid_from]
    valid_until = source[:valid_until]
    fresh_until = observed_at && observed_at + freshness_days.days

    status = "not_yet_valid" if status == "available" && valid_from && valid_from > @at
    status = "expired" if status == "available" && valid_until && valid_until <= @at
    status = "unavailable" if status == "available" && (!observed_at || observed_at > @at)
    status = "stale" if status == "available" && fresh_until <= @at
    Result.new({
      "kind" => kind,
      "locator" => locator,
      "status" => STATUSES.include?(status) ? status : "unavailable",
      "observed_at" => observed_at&.iso8601(6),
      "valid_until" => valid_until&.iso8601(6),
      "fresh_until" => fresh_until&.iso8601(6)
    })
  rescue ActiveRecord::ActiveRecordError, ArgumentError, TypeError
    Result.new(unavailable_snapshot(kind, locator))
  end

  private
    def source_for(kind, locator)
      case kind
      when "knowledge" then knowledge_source(locator)
      when "conversation" then conversation_source(locator)
      when "case" then case_source(locator)
      when "account" then account_source(locator)
      when "health_signal" then health_signal_source(locator)
      when "public_web" then public_web_source(locator)
      when "memory" then memory_source(locator)
      else unavailable
      end
    end

    def knowledge_source(locator)
      match = locator.match(%r{\Aknowledge://sources/([0-9a-f-]{36})/versions/(\d+)\z})
      source = match && @workspace.knowledge_sources.find_by(source_key: match[1])
      version = source && source.versions.find_by(version_number: match[2].to_i)
      return unavailable unless version&.citation_uri == locator

      {
        status: source.deleted? ? "deleted" : "available",
        observed_at: version.retrieved_at,
        valid_until: version.expires_at
      }
    end

    def conversation_source(locator)
      match = locator.match(%r{\Aconversation://(\d+)/messages/(\d+)\z})
      return unavailable unless match

      conversation = if @task.support_case
        @task.support_case.conversation
      else
        @workspace.conversations.where(contact_id: @task.account.contacts.select(:id)).find_by(id: match[1])
      end
      message = conversation&.conversation_messages&.find_by(id: match[2])
      return unavailable unless conversation&.id == match[1].to_i && message

      { observed_at: message.occurred_at }
    end

    def case_source(locator)
      return unavailable unless @task.support_case && locator == "case://#{@task.support_case_id}"

      { observed_at: @task.support_case.status_changed_at }
    end

    def account_source(locator)
      account = scoped_account
      return unavailable unless account && locator == "account://#{account.id}"

      { observed_at: account.updated_at }
    end

    def health_signal_source(locator)
      match = locator.match(%r{\Ahealth://assessments/(\d+)/signals/([a-z0-9_]+)\z})
      account = scoped_account
      signal = match && account && @workspace.account_health_signals.joins(:account_health_assessment)
        .find_by(account_health_assessment_id: match[1], signal_key: match[2],
          account_health_assessments: { account_id: account.id })
      return unavailable unless signal&.citation_uri == locator

      { observed_at: signal.range_ends_at }
    end

    def public_web_source(locator)
      match = locator.match(%r{\Apublic-web://([0-9a-f-]{36})\z})
      result = match && @workspace.public_web_search_results.joins(:public_web_search)
        .find_by(citation_key: match[1], public_web_searches: { crew_task_id: @task.id, status: "completed" })
      return unavailable unless result

      { observed_at: result.retrieved_at }
    end

    def memory_source(locator)
      match = locator.match(%r{\Amemory://([0-9a-f-]{36})\z})
      selection = match && @run.execution_memory_selections.joins(:memory_record)
        .find_by(memory_records: { memory_key: match[1] })
      record = selection&.memory_record
      return unavailable unless record

      status = if record.memory_tombstone
        "deleted"
      elsif record.revisions.exists?
        "conflicted"
      else
        "available"
      end
      valid_until = [ record.valid_until, record.retention_until ].compact.min
      {
        status:,
        observed_at: record.observed_at,
        valid_from: record.valid_from,
        valid_until:
      }
    end

    def scoped_account
      @task.account || @task.support_case&.conversation&.contact&.account
    end

    def unavailable
      { status: "unavailable" }
    end

    def unavailable_snapshot(kind, locator)
      {
        "kind" => kind.to_s,
        "locator" => locator.to_s,
        "status" => "unavailable",
        "observed_at" => nil,
        "valid_until" => nil,
        "fresh_until" => nil
      }
    end
end
