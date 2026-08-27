class CrewArtifactPublisher
  class InvalidOutput < StandardError; end
  class Conflict < InvalidOutput; end

  SCHEMA_V1_KEYS = %w[
    schema_version kind body uncertainty citations conflicts change_requests review_outcome memory_proposals
  ].sort.freeze
  SCHEMA_V2_KEYS = (SCHEMA_V1_KEYS + %w[
    required_facts material_claims proposed_actions policy_checks
  ]).sort.freeze
  ROLE_KINDS = {
    "support_investigator" => "investigation",
    "resolution_drafter" => "draft",
    "support_reviewer" => "quality_review",
    "account_analyst" => "account_analysis",
    "risk_investigator" => "risk_investigation",
    "success_strategist" => "intervention_plan",
    "success_reviewer" => "success_review"
  }.freeze
  REVIEW_TARGET_KINDS = { "quality_review" => "draft", "success_review" => "intervention_plan" }.freeze
  CITATION_KEYS = %w[kind label locator].sort.freeze
  CONFLICT_KEYS = %w[details severity summary].sort.freeze
  CONFLICT_SEVERITIES = %w[info warning blocking].freeze

  def self.publish!(workspace:, task:, run:, target_artifact: nil)
    new(workspace:).publish!(task:, run:, target_artifact:)
  end

  def self.supports?(run)
    ROLE_KINDS.key?(run.agent_profile.role_key)
  end

  def initialize(workspace:)
    @workspace = workspace
  end

  def publish!(task:, run:, target_artifact: nil)
    task = @workspace.crew_tasks.find(task.id)
    run = @workspace.execution_runs.find(run.id)
    raise InvalidOutput, "Run does not belong to this task." unless run.crew_task_id == task.id
    raise InvalidOutput, "Only a completed run can publish output." unless run.completed?

    digest = Digest::SHA256.hexdigest(run.output.to_s)
    payload = parse(run.output)
    kind = ROLE_KINDS.fetch(run.agent_profile.role_key) do
      raise InvalidOutput, "This specialist cannot publish a crew artifact."
    end
    raise InvalidOutput, "Output kind does not match the specialist role." unless payload.fetch("kind") == kind

    CrewArtifact.transaction do
      CrewScopeLock.acquire!(workspace: @workspace, scope: task)
      task.lock!
      run.lock!
      if (existing = @workspace.crew_artifacts.find_by(execution_run: run))
        return existing if existing.payload_digest == digest
        raise Conflict, "This run already published different output."
      end
      latest = task.artifacts.unscope(:order).where(artifact_kind: kind).order(version_number: :desc).first
      if latest && latest.execution_run.attempt_number >= run.attempt_number
        raise Conflict, "A newer output version already exists."
      end

      target = review_target!(task, run, kind, target_artifact)
      schema_version = payload.fetch("schema_version")
      citations = citations!(task, run, payload.fetch("citations"), schema_version:)
      conflicts = conflicts!(payload.fetch("conflicts"))
      evaluation = resolution_evaluation(task, run, payload, citations, conflicts)
      review_outcome = review_outcome!(kind, payload, target:, evaluation:)
      resolution_attributes = evaluation ? evaluation.attributes : {}
      artifact = @workspace.crew_artifacts.create!(
        crew_task: task, execution_run: run, artifact_kind: kind,
        schema_version:,
        version_number: latest&.version_number.to_i + 1,
        supersedes_artifact: latest,
        target_artifact: target,
        body: bounded_text(payload.fetch("body"), 50.kilobytes, "Body"),
        uncertainty: bounded_text(payload.fetch("uncertainty"), 4_000, "Uncertainty"),
        review_outcome:,
        citations:,
        conflicts:,
        change_requests: change_requests!(kind, payload),
        payload_digest: digest,
        **resolution_attributes
      )
      audit_metadata = {
        "artifact_kind" => kind,
        "version" => artifact.version_number,
        "schema_version" => artifact.schema_version
      }
      if evaluation
        audit_metadata["contract_version"] = evaluation.resolution_contract_version.version_number
        audit_metadata["contract_result"] = evaluation.contract_result_state
      end
      AuditEvent.record!(
        action: "crew.artifact_published", source: :runner, workspace: @workspace,
        actor_kind: :system, subject: artifact,
        metadata: audit_metadata
      )
      publish_memory_proposals!(task, artifact, payload.fetch("memory_proposals"))
      artifact
    end
  rescue JSON::ParserError, TypeError, KeyError
    raise InvalidOutput, "Run output does not match artifact schema."
  rescue ResolutionContractEvaluator::InvalidPayload => error
    raise InvalidOutput, error.message
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidOutput, error.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    raise Conflict, "Output version changed concurrently."
  end

  private
    def parse(raw)
      raise InvalidOutput, "Run output is missing." if raw.blank? || raw.bytesize > 100.kilobytes

      payload = JSON.parse(raw)
      schema_version = payload.is_a?(Hash) && payload["schema_version"]
      expected_keys = { 1 => SCHEMA_V1_KEYS, 2 => SCHEMA_V2_KEYS }[schema_version]
      unless expected_keys && payload.keys.sort == expected_keys
        raise InvalidOutput, "Run output does not match artifact schema."
      end
      unless %w[citations conflicts change_requests].all? { |key| payload[key].is_a?(Array) && payload[key].size <= 20 } &&
          payload["memory_proposals"].is_a?(Array) && payload["memory_proposals"].size <= 10
        raise InvalidOutput, "Run output collections are invalid."
      end
      payload
    end

    def review_target!(task, run, kind, value)
      target_kind = REVIEW_TARGET_KINDS[kind]
      unless target_kind
        raise InvalidOutput, "Only a review can target an artifact." if value.present?
        return nil
      end
      if value.present? && value != run.input_artifact
        raise InvalidOutput, "Quality review target changed after the run started."
      end
      value ||= run.input_artifact
      raise InvalidOutput, "A review must target the latest #{target_kind.humanize.downcase}." if value.blank?

      target = @workspace.crew_artifacts.find(value.id)
      latest = @workspace.crew_artifacts.joins(:crew_task)
        .where(artifact_kind: target_kind, crew_tasks: scope_filter(task)).order(created_at: :desc, id: :desc).first
      unless target.artifact_kind == target_kind && target == latest && same_scope?(task, target.crew_task)
        raise InvalidOutput, "A review must target the latest #{target_kind.humanize.downcase}."
      end
      target
    end

    def citations!(task, run, values, schema_version:)
      unless values.is_a?(Array) && values.size.in?(1..20)
        raise InvalidOutput, "Citations must contain between 1 and 20 entries."
      end
      values.map do |value|
        unless value.is_a?(Hash) && value.keys.sort == CITATION_KEYS
          raise InvalidOutput, "A citation does not match the schema."
        end
        kind = value.fetch("kind").to_s
        locator = bounded_text(value.fetch("locator"), 2_000, "Citation locator")
        label = bounded_text(value.fetch("label"), 200, "Citation label")
        validate_locator!(task, run, kind, locator) if schema_version == 1
        { "kind" => kind, "locator" => locator, "label" => label }
      end
    end

    def validate_locator!(task, run, kind, locator)
      unless ResolutionContractVersion::SOURCE_KINDS.key?(kind)
        raise InvalidOutput, "Citation type is not supported."
      end

      result = CrewEvidenceResolver.new(workspace: @workspace, task:, run:)
        .resolve(kind:, locator:, freshness_days: ResolutionContractVersion::FRESHNESS_DAYS_RANGE.end)
      raise InvalidOutput, "#{kind.humanize} citation is unavailable." unless result.available?
    end

    def conflicts!(values)
      unless values.is_a?(Array) && values.size <= 20
        raise InvalidOutput, "Conflicts must be an array with at most 20 entries."
      end
      values.map do |value|
        unless value.is_a?(Hash) && value.keys.sort == CONFLICT_KEYS &&
            CONFLICT_SEVERITIES.include?(value.fetch("severity"))
          raise InvalidOutput, "A conflict does not match the schema."
        end
        {
          "summary" => bounded_text(value.fetch("summary"), 200, "Conflict summary"),
          "details" => bounded_text(value.fetch("details"), 2_000, "Conflict details"),
          "severity" => value.fetch("severity")
        }
      end
    end

    def review_outcome!(kind, payload, target:, evaluation:)
      outcome = payload.fetch("review_outcome")
      if REVIEW_TARGET_KINDS.key?(kind)
        raise InvalidOutput, "Review outcome is invalid." unless CrewArtifact::REVIEW_OUTCOMES.include?(outcome)
        has_blocker = payload.fetch("conflicts").any? { |conflict| conflict.is_a?(Hash) && conflict["severity"] == "blocking" }
        raise InvalidOutput, "A review with blocking conflicts cannot be approved." if outcome == "approved" && has_blocker
        if outcome == "approved" && target.contract_blocking?
          raise InvalidOutput, "A blocking artifact cannot receive an approved review."
        end
        if outcome == "approved" && evaluation&.contract_result_state == "blocked"
          raise InvalidOutput, "A blocking review cannot be approved."
        end
      elsif outcome.present?
        raise InvalidOutput, "Only a review can record an outcome."
      end
      outcome
    end

    def resolution_evaluation(task, run, payload, citations, conflicts)
      return unless payload.fetch("schema_version") == 2

      family_key = task.crew_template.support? ? "support_resolution" : "customer_success_intervention"
      family = @workspace.resolution_contract_families.find_by(family_key:)
      raise InvalidOutput, "Resolution contract is unavailable for this task." unless family

      family.lock!
      contract = family.current_version
      raise InvalidOutput, "Resolution contract is unavailable for this task." unless contract

      ResolutionContractEvaluator.new(
        workspace: @workspace, task:, run:, contract_version: contract
      ).evaluate!(payload:, citations:, conflicts:)
    end

    def change_requests!(kind, payload)
      values = payload.fetch("change_requests")
      unless values.is_a?(Array) && values.size <= 20
        raise InvalidOutput, "Change requests must be an array with at most 20 entries."
      end
      if !REVIEW_TARGET_KINDS.key?(kind) && values.present?
        raise InvalidOutput, "Only a review can request changes."
      end
      if REVIEW_TARGET_KINDS.key?(kind) && (payload.fetch("review_outcome") == "changes_requested") != values.present?
        raise InvalidOutput, "Change requests do not match the review outcome."
      end
      values.map { |value| bounded_text(value, 2_000, "Change request") }
    end

    def bounded_text(value, maximum, name)
      raise InvalidOutput, "#{name} must be text." unless value.is_a?(String)

      text = value.strip
      if text.blank? || text.bytesize > maximum
        raise InvalidOutput, "#{name} is required and must be at most #{maximum} bytes."
      end
      text
    end

    def publish_memory_proposals!(task, artifact, values)
      values.each do |value|
        unless value.is_a?(Hash) && value.keys.sort == %w[confidence content memory_type scope_kind topic]
          raise InvalidOutput, "A memory proposal does not match the schema."
        end
        scope = proposal_scope!(task, value.fetch("scope_kind"))
        MemoryPublication.propose!(
          workspace: @workspace, artifact:, memory_type: value.fetch("memory_type"), scope:,
          topic: bounded_text(value.fetch("topic"), 200, "Memory topic"),
          content: bounded_text(value.fetch("content"), 32_768, "Memory content"),
          confidence: value.fetch("confidence")
        )
      end
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      raise InvalidOutput, error.message
    end

    def proposal_scope!(task, kind)
      case kind
      when "support_case"
        task.support_case || raise(InvalidOutput, "Case memory is unavailable for this task.")
      when "contact"
        task.support_case&.conversation&.contact || raise(InvalidOutput, "Contact memory is unavailable for this task.")
      when "account"
        task.account || task.support_case&.conversation&.contact&.account ||
          raise(InvalidOutput, "Account memory is unavailable for this task.")
      else
        raise InvalidOutput, "Memory proposal scope is unsupported."
      end
    end

    def same_scope?(left, right)
      left.scope_kind == right.scope_kind && left.support_case_id == right.support_case_id && left.account_id == right.account_id
    end

    def scope_filter(task)
      { scope_kind: task.scope_kind, support_case_id: task.support_case_id, account_id: task.account_id }
    end
end
