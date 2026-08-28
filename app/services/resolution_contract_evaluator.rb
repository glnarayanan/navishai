class ResolutionContractEvaluator
  class InvalidPayload < StandardError; end

  Evaluation = Data.define(
    :resolution_contract_version, :required_facts, :material_claims, :proposed_actions,
    :policy_checks, :contract_result_state, :contract_blockers, :contract_evaluated_at
  ) do
    def attributes
      to_h
    end
  end

  CLAIM_KEYS = %w[category evidence key state text].sort.freeze
  EVIDENCE_KEYS = %w[kind locator].sort.freeze
  POLICY_CHECK_KEYS = %w[check status].sort.freeze
  CLAIM_STATES = %w[supported uncertain conflicted refused].freeze
  POLICY_CHECK_STATUSES = %w[passed failed needs_human].freeze
  POLICY_CHECK_STATUS_RANK = { "passed" => 0, "needs_human" => 1, "failed" => 2 }.freeze
  BLOCKER_REMEDIATION = {
    "uncertain" => "Add current evidence or qualify the claim for human review.",
    "conflicted" => "Resolve the conflict or state which authoritative source controls.",
    "refused" => "Supply the required evidence or keep the refusal in the human review.",
    "stale" => "Refresh the cited source and run the specialist again.",
    "expired" => "Replace the expired source with current evidence.",
    "deleted" => "Replace the deleted source with available evidence.",
    "unavailable" => "Use an available source from this Workspace and task scope.",
    "not_yet_valid" => "Use evidence that is valid at the evaluation time.",
    "superseded" => "Use the accepted replacement instead of the superseded memory."
  }.freeze

  def initialize(workspace:, task:, run:, contract_version:, evaluated_at: Time.current)
    @workspace = workspace
    @task = task
    @run = run
    @contract = contract_version
    @evaluated_at = evaluated_at
    @resolver = CrewEvidenceResolver.new(workspace:, task:, run:, at: evaluated_at)
  end

  def evaluate!(payload:, citations:, conflicts:)
    validate_contract!
    bounded_text(payload.fetch("uncertainty"), 4_000, "Uncertainty")
    required_facts = required_facts!(payload.fetch("required_facts"))
    citation_refs = citations.to_set { |citation| [ citation.fetch("kind"), citation.fetch("locator") ] }
    claims = material_claims!(payload.fetch("material_claims"), citation_refs)
    validate_required_facts!(required_facts, claims)
    actions = proposed_actions!(payload.fetch("proposed_actions"))
    checks = policy_checks!(payload.fetch("policy_checks"), claims, conflicts)
    blockers = blockers_for(claims, checks, conflicts)
    result = if blockers.empty?
      "complete"
    elsif blockers.any? { |blocker| blocker.fetch("severity") == "blocking" }
      "blocked"
    else
      "needs_human"
    end

    Evaluation.new(
      @contract, required_facts, claims, actions, checks, result, blockers, @evaluated_at
    )
  rescue KeyError, TypeError
    raise InvalidPayload, "Run output does not match artifact schema."
  end

  private
    def validate_contract!
      expected_family = @task.crew_template.support? ? "support_resolution" : "customer_success_intervention"
      family = @contract.resolution_contract_family
      unless @contract.workspace_id == @workspace.id && family.workspace_id == @workspace.id &&
          family.family_key == expected_family
        raise InvalidPayload, "Resolution contract is unavailable for this task."
      end
    end

    def required_facts!(values)
      unless values.is_a?(Array) && values.size.in?(1..20) && values.all? { |value| claim_key?(value) } &&
          values.uniq.size == values.size
        raise InvalidPayload, "Required facts must contain distinct bounded claim keys."
      end
      values
    end

    def material_claims!(values, citation_refs)
      unless values.is_a?(Array) && values.size.in?(1..20)
        raise InvalidPayload, "Material claims must contain between 1 and 20 entries."
      end
      claims = values.map { |value| material_claim!(value, citation_refs) }
      raise InvalidPayload, "Material claim keys must be distinct." unless claims.map { |claim| claim.fetch("key") }.uniq.size == claims.size

      claims
    end

    def material_claim!(value, citation_refs)
      unless value.is_a?(Hash) && value.keys.sort == CLAIM_KEYS && claim_key?(value.fetch("key")) &&
          ResolutionContractVersion::CLAIM_CATEGORIES.key?(value.fetch("category")) &&
          CLAIM_STATES.include?(value.fetch("state"))
        raise InvalidPayload, "A material claim does not match the schema."
      end
      text = bounded_text(value.fetch("text"), 4_000, "Material claim")
      evidence = evidence!(value.fetch("evidence"), citation_refs)
      declared_state = value.fetch("state")
      if declared_state != "refused" && evidence.empty?
        raise InvalidPayload, "A material claim must cite evidence or be refused."
      end

      evaluated_state = if declared_state == "supported" && evidence.any? { |item| item.fetch("status") == "conflicted" }
        "conflicted"
      elsif declared_state == "supported" && evidence.any? { |item| item.fetch("status") != "available" }
        "uncertain"
      else
        declared_state
      end
      {
        "key" => value.fetch("key"),
        "category" => value.fetch("category"),
        "text" => text,
        "state" => evaluated_state,
        "evidence" => evidence
      }
    end

    def evidence!(values, citation_refs)
      unless values.is_a?(Array) && values.size <= 20
        raise InvalidPayload, "Claim evidence must be an array with at most 20 entries."
      end
      references = values.map do |value|
        unless value.is_a?(Hash) && value.keys.sort == EVIDENCE_KEYS &&
            ResolutionContractVersion::SOURCE_KINDS.key?(value.fetch("kind"))
          raise InvalidPayload, "Claim evidence does not match the schema."
        end
        kind = value.fetch("kind")
        locator = bounded_text(value.fetch("locator"), 2_000, "Evidence locator")
        unless citation_refs.include?([ kind, locator ])
          raise InvalidPayload, "Claim evidence must link to a declared citation."
        end
        [ kind, locator ]
      end
      raise InvalidPayload, "Claim evidence must be distinct." unless references.uniq.size == references.size

      references.map do |kind, locator|
        @resolver.resolve(
          kind:, locator:,
          freshness_days: @contract.evidence_freshness_days.fetch(kind)
        ).snapshot
      end
    end

    def validate_required_facts!(required_facts, claims)
      claim_keys = claims.to_h { |claim| [ claim.fetch("key"), claim ] }
      missing = required_facts - claim_keys.keys
      raise InvalidPayload, "Required facts must link to material claims." if missing.any?
    end

    def proposed_actions!(values)
      unless values.is_a?(Array) && values.size <= 20
        raise InvalidPayload, "Proposed actions must be an array with at most 20 entries."
      end
      values.map { |value| bounded_text(value, 2_000, "Proposed action") }
    end

    def policy_checks!(values, claims, conflicts)
      unless values.is_a?(Array) && values.size <= ResolutionContractVersion::REVIEW_CHECKS.size
        raise InvalidPayload, "Policy checks are invalid."
      end
      checks = values.map do |value|
        unless value.is_a?(Hash) && value.keys.sort == POLICY_CHECK_KEYS &&
            ResolutionContractVersion::REVIEW_CHECKS.key?(value.fetch("check")) &&
            POLICY_CHECK_STATUSES.include?(value.fetch("status"))
          raise InvalidPayload, "A policy check does not match the schema."
        end
        key = value.fetch("check")
        derived = derived_policy_check_status(key, claims:, conflicts:)
        {
          "check" => key,
          "status" => conservative_status(value.fetch("status"), derived)
        }
      end
      raise InvalidPayload, "Policy checks must be distinct." unless checks.map { |check| check.fetch("check") }.uniq.size == checks.size

      by_key = checks.index_by { |check| check.fetch("check") }
      @contract.mandatory_review_checks.each do |key|
        by_key[key] ||= { "check" => key, "status" => "failed" }
      end
      by_key.values.sort_by { |check| check.fetch("check") }
    end

    def derived_policy_check_status(key, claims:, conflicts:)
      case key
      when "claims_grounded"
        grounded = claims.all? do |claim|
          claim.fetch("state") == "supported" &&
            claim.fetch("evidence").all? { |evidence| evidence.fetch("status") == "available" }
        end
        grounded ? "passed" : "failed"
      when "conflicts_resolved"
        resolved = claims.none? { |claim| claim.fetch("state") == "conflicted" } &&
          claims.all? do |claim|
            claim.fetch("evidence").none? { |evidence| evidence.fetch("status") == "conflicted" }
          end && conflicts.none? { |conflict| conflict.fetch("severity") != "info" }
        resolved ? "passed" : "failed"
      when "uncertainty_stated"
        typed_unresolved?(claims, conflicts) ? "needs_human" : "passed"
      when "human_authority_preserved"
        # Publishing proposed action text has no path to create, send, or schedule an external effect.
        "passed"
      end
    end

    def typed_unresolved?(claims, conflicts)
      claims.any? do |claim|
        claim.fetch("state") != "supported" ||
          claim.fetch("evidence").any? { |evidence| evidence.fetch("status") != "available" }
      end || conflicts.any? { |conflict| conflict.fetch("severity") != "info" }
    end

    def conservative_status(submitted, derived)
      [ submitted, derived ].max_by { |status| POLICY_CHECK_STATUS_RANK.fetch(status) }
    end

    def blockers_for(claims, checks, conflicts)
      blockers = []
      claims.each do |claim|
        blockers << claim_blocker(claim) unless claim.fetch("state") == "supported"
      end
      @contract.required_claim_categories.each do |category|
        next if claims.any? { |claim| claim.fetch("category") == category }

        blockers << blocker(
          code: "missing_claim_category",
          message: "Required material claim category #{category.humanize.downcase} is missing.",
          remediation: "Add a cited claim or an explicit refusal for this category."
        )
      end
      checks.each do |check|
        next unless @contract.mandatory_review_checks.include?(check.fetch("check"))
        next if check.fetch("status") == "passed"

        blockers << blocker(
          code: "review_check_#{check.fetch('status')}",
          message: "Mandatory review check #{check.fetch('check').humanize.downcase} did not pass.",
          remediation: "Resolve this check and run the specialist review again.",
          severity: check.fetch("status") == "needs_human" ? "review" : missing_severity
        )
      end
      conflicts.each do |conflict|
        next if conflict.fetch("severity") == "info"

        blockers << blocker(
          code: "known_conflict",
          message: conflict.fetch("summary"),
          remediation: "Resolve the recorded conflict or keep the result in human review.",
          severity: conflict.fetch("severity") == "blocking" ? "blocking" : "review"
        )
      end
      if @run.input_units + @run.output_units > @contract.execution_budget_units
        blockers << blocker(
          code: "execution_budget_exceeded",
          message: "Observed execution units exceed the published contract threshold.",
          remediation: "Review the run and use a new bounded attempt before readiness.",
          severity: "blocking"
        )
      end
      blockers.uniq
    end

    def claim_blocker(claim)
      evidence_status = claim.fetch("evidence").filter_map do |item|
        item.fetch("status") unless item.fetch("status") == "available"
      end.first
      state = evidence_status || claim.fetch("state")
      blocker(
        code: "claim_#{state}",
        claim_key: claim.fetch("key"),
        message: "Material claim #{claim.fetch('key').humanize.downcase} is #{state.humanize.downcase}.",
        remediation: BLOCKER_REMEDIATION.fetch(state, BLOCKER_REMEDIATION.fetch(claim.fetch("state")))
      )
    end

    def blocker(code:, message:, remediation:, claim_key: nil, severity: missing_severity)
      {
        "code" => code,
        "claim_key" => claim_key,
        "message" => message,
        "remediation" => remediation,
        "severity" => severity
      }
    end

    def missing_severity
      @contract.missing_items_block? ? "blocking" : "review"
    end

    def claim_key?(value)
      value.is_a?(String) && value.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
    end

    def bounded_text(value, maximum, name)
      raise InvalidPayload, "#{name} must be text." unless value.is_a?(String)

      text = value.strip
      if text.blank? || text.bytesize > maximum
        raise InvalidPayload, "#{name} is required and must be at most #{maximum} bytes."
      end
      text
    end
end
