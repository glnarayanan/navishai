class HealthScorecardProposalPublisher
  class InvalidOutput < StandardError; end
  class Conflict < InvalidOutput; end

  KEYS = %w[assumptions definition explanation kind missing_evidence schema_version unsupported_requests].freeze
  PREDICTION_CLAIM = /\b(validated prediction|predict(?:s|ing)? churn|churn model)\b/i
  FORBIDDEN_TEXT = /
    \b(SELECT|INSERT|UPDATE|DELETE|DROP|ALTER)\b.{0,40}\b(FROM|INTO|TABLE|DATABASE)\b |
    ``` |
    <script |
    \b(curl|wget)\s |
    \bdef\s+[A-Za-z_] |
    ;\s*(DROP|DELETE|UPDATE)\b
  /ix

  def self.publish!(workspace:, task:, run:)
    new(workspace:).publish!(task:, run:)
  end

  def initialize(workspace:)
    @workspace = workspace
  end

  def publish!(task:, run:)
    task = @workspace.crew_tasks.find(task.id)
    run = @workspace.execution_runs.find(run.id)
    raise InvalidOutput, "Run does not belong to this task." unless run.crew_task_id == task.id
    raise InvalidOutput, "Only a completed scorecard proposal run can be retained." unless run.completed?
    raise InvalidOutput, "This task is not a scorecard proposal." unless task.scope_kind == "health_scorecard"

    digest = Digest::SHA256.hexdigest(run.output.to_s)
    parsed = parse(run.output)

    HealthScorecardProposal.transaction do
      CrewScopeLock.acquire!(workspace: @workspace, scope: task)
      task.lock!
      run.lock!
      if (existing = @workspace.health_scorecard_proposals.find_by(execution_run: run))
        return existing if existing.payload_digest == digest
        raise Conflict, "This run already published a different scorecard proposal."
      end

      proposal = @workspace.health_scorecard_proposals.create!(
        health_scorecard: task.health_scorecard, crew_task: task, execution_run: run,
        created_by_membership: run.requested_by_membership || task.owner_membership,
        created_by_user: (run.requested_by_membership || task.owner_membership).user,
        prompt: extract_prompt(task),
        proposed_definition: parsed[:definition], explanation: parsed[:explanation],
        assumptions: parsed[:assumptions], unsupported_requests: parsed[:unsupported_requests],
        missing_evidence: parsed[:missing_evidence], validation_status: parsed[:status],
        validation_detail: parsed[:detail], payload_digest: digest
      )
      AuditEvent.record!(
        action: "scorecard.proposal_generated", source: :runner, workspace: @workspace,
        actor_kind: :system, subject: proposal,
        metadata: {
          "validation_status" => proposal.validation_status,
          "adapter" => run.selected_adapter_key.to_s
        }
      )
      proposal
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidOutput, error.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    raise Conflict, "Scorecard proposal identity changed concurrently."
  end

  private
    def parse(raw)
      raise InvalidOutput, "Run output is missing." if raw.blank? || raw.bytesize > 100.kilobytes

      payload = JSON.parse(raw)
      unless payload.is_a?(Hash) && payload.keys.sort == KEYS && payload["schema_version"] == 1 &&
          payload["kind"] == "scorecard_proposal"
        return rejected("invalid", "Run output does not match the scorecard proposal schema.", payload)
      end

      begin
        explanation = bounded_text(payload["explanation"], 8_000, "Explanation")
        assumptions = string_list(payload["assumptions"], "Assumption")
        unsupported = string_list(payload["unsupported_requests"], "Unsupported request")
        missing = string_list(payload["missing_evidence"], "Missing evidence")
      rescue InvalidOutput => error
        return rejected("invalid", error.message, payload)
      end
      texts = [ explanation, *assumptions, *unsupported, *missing ]
      if texts.any? { |text| FORBIDDEN_TEXT.match?(text) }
        return result("invalid", nil, explanation, assumptions, unsupported, missing,
          "Proposal text contains SQL, code, or extra commands.")
      end
      if PREDICTION_CLAIM.match?([ explanation, *assumptions ].join(" "))
        return result("invalid", nil, explanation, assumptions, unsupported, missing,
          "A scorecard proposal must not claim a validated prediction.")
      end

      definition = payload["definition"]
      if definition.nil?
        status = unsupported.present? ? "unsupported" : "incomplete"
        detail = status == "unsupported" ? "The request is outside the supported signal catalog." :
          "The proposal did not include a scorecard definition."
        return result(status, nil, explanation, assumptions, unsupported, missing, detail)
      end

      begin
        HealthScorecardDefinition.validate!(definition)
      rescue HealthScorecardDefinition::InvalidDefinition => error
        return result("invalid", nil, explanation, assumptions, unsupported, missing, error.message)
      end
      result("valid", definition, explanation, assumptions, unsupported, missing, nil)
    rescue JSON::ParserError, TypeError
      rejected("invalid", "Run output does not match the scorecard proposal schema.", nil)
    end

    def rejected(status, detail, payload)
      explanation = payload.is_a?(Hash) && payload["explanation"].is_a?(String) && payload["explanation"].strip.present? ?
        payload["explanation"].to_s.strip.truncate_bytes(8_000, omission: "") : "The runner output was not a valid scorecard proposal."
      result(status, nil, explanation, [], [], [], detail)
    end

    def result(status, definition, explanation, assumptions, unsupported, missing, detail)
      {
        status:, definition:, explanation:, assumptions:, unsupported_requests: unsupported,
        missing_evidence: missing, detail:
      }
    end

    def string_list(value, label)
      unless value.is_a?(Array) && value.size <= 20
        raise InvalidOutput, "#{label} list is invalid."
      end
      value.map { |entry| bounded_text(entry, 1_000, label) }
    end

    def bounded_text(value, maximum, name)
      raise InvalidOutput, "#{name} must be text." unless value.is_a?(String)

      text = value.strip
      raise InvalidOutput, "#{name} is required and must be at most #{maximum} bytes." if text.blank? || text.bytesize > maximum

      text
    end

    def extract_prompt(task)
      payload = JSON.parse(task.input_context.split("\n", 2).last)
      prompt = payload.fetch("user_prompt").to_s.strip
      raise InvalidOutput, "The retained task is missing the user prompt." unless prompt.bytesize.in?(1..2_000)

      prompt
    rescue JSON::ParserError, TypeError, KeyError
      raise InvalidOutput, "The retained task is missing the user prompt."
    end
end
