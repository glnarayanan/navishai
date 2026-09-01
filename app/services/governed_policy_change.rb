require "digest"
require "json"

class GovernedPolicyChange
  class InvalidChange < StandardError; end
  class StalePreview < InvalidChange; end
  class UnavailableSource < InvalidChange; end

  MAX_SUBJECTS = 50
  PROFILE_POLICY_FIELDS = %i[
    runtime_profile_key fallback_profile_keys timeout_seconds max_steps max_tool_calls review_policy isolation_policy
  ].freeze
  CONTRACT_FIELDS = %i[
    required_claim_categories evidence_freshness_days mandatory_review_checks execution_budget_units
    missing_items_block
  ].freeze

  def self.propose!(**attributes)
    new(workspace: attributes.delete(:workspace), membership: attributes.delete(:membership)).propose!(**attributes)
  end

  def self.preview!(**attributes)
    new(workspace: attributes.delete(:workspace), membership: attributes.delete(:membership)).preview!(**attributes)
  end

  def self.publish!(**attributes)
    new(workspace: attributes.delete(:workspace), membership: attributes.delete(:membership)).publish!(**attributes)
  end

  def self.rollback!(**attributes)
    new(workspace: attributes.delete(:workspace), membership: attributes.delete(:membership)).rollback!(**attributes)
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
  end

  def self.canonical(value)
    case value
    when Hash
      value.keys.map(&:to_s).sort.to_h do |key|
        source_key = value.key?(key) ? key : key.to_sym
        [ key, canonical(value.fetch(source_key)) ]
      end
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end
  private_class_method :canonical

  def initialize(workspace:, membership:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
    authorize!
  end

  def propose!(family:, profile:, scope_kind:, scope_ids:, contract_attributes:, profile_attributes:, reason:)
    family = @workspace.resolution_contract_families.find(family.id)
    profile = @workspace.agent_profiles.includes(:current_version, :crew_template).find(profile.id)
    validate_family_profile!(family, profile)
    subjects = scoped_subjects!(scope_kind, scope_ids, profile)
    reason = bounded_reason(reason)

    GovernedPolicyProposal.transaction do
      GovernedPolicyResolver.lock_workspace!(@workspace)
      family.lock!
      profile.lock!
      prior_contract = family.current_version
      prior_profile = profile.current_version
      candidate_contract = build_contract_version!(family, contract_attributes)
      candidate_profile = build_profile_version!(profile, prior_profile, profile_attributes)
      proposal = @workspace.governed_policy_proposals.create!(
        resolution_contract_family: family, agent_profile: profile,
        prior_resolution_contract_version: prior_contract,
        resolution_contract_version: candidate_contract,
        prior_agent_profile_version: prior_profile, agent_profile_version: candidate_profile,
        scope_kind:, reason:, created_by_membership: @membership, created_by_user: @membership.user
      )
      subjects.each do |subject|
        proposal.subjects.create!(
          workspace: @workspace, subject_kind: scope_kind,
          "#{scope_kind}_id" => subject.id
        )
      end
      AuditEvent.record!(
        action: "governed_policy.proposed", source: :web, workspace: @workspace,
        actor: @membership.user, subject: proposal,
        metadata: { "scope_kind" => scope_kind, "subject_count" => subjects.size }
      )
      proposal
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidChange, error.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    raise InvalidChange, "Policy versions changed concurrently. Review current policy and try again."
  end

  def preview!(proposal:)
    proposal = scoped_proposal(proposal)
    ensure_retained!(proposal, "Proposal evidence")
    source_snapshot = source_snapshot(proposal)
    results = preview_results(proposal, source_snapshot)
    evidence_digest = digest(source_snapshot)
    results_digest = digest(results)
    existing = proposal.previews.find_by(evidence_digest:, results_digest:)
    return existing if existing

    @workspace.governed_policy_previews.create!(
      proposal:, evidence_digest:, results_digest:, source_snapshot:, results:,
      subject_count: results.size, created_by_membership: @membership,
      created_by_user: @membership.user, previewed_at: Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    proposal.previews.find_by!(evidence_digest:, results_digest:)
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidChange, error.record.errors.full_messages.to_sentence
  end

  def publish!(proposal:, preview:)
    raise InvalidChange, "A current retained-fact preview is required before publication." unless preview

    GovernedPolicyPublication.transaction do
      GovernedPolicyResolver.lock_workspace!(@workspace)
      proposal = scoped_proposal(proposal)
      preview = @workspace.governed_policy_previews.find(preview.id)
      raise InvalidChange, "Preview does not belong to this proposal." unless preview.governed_policy_proposal_id == proposal.id
      ensure_retained!(proposal, "Proposal evidence")
      ensure_retained!(preview, "Preview evidence")
      ensure_sources_available!(proposal)
      validate_current_security!(proposal)
      current_snapshot = source_snapshot(proposal)
      current_results = preview_results(proposal, current_snapshot)
      stored_payloads_match = preview.evidence_digest == digest(preview.source_snapshot) &&
        preview.results_digest == digest(preview.results)
      current_payloads_match = preview.source_snapshot == current_snapshot && preview.results == current_results
      raise StalePreview, "The preview evidence is stale or does not match its digest." unless
        stored_payloads_match && current_payloads_match

      previous = latest_for_scope(proposal)
      publication = @workspace.governed_policy_publications.create!(
        proposal:, preview:, supersedes_publication: previous, action: "canary",
        resolution_contract_version: proposal.resolution_contract_version,
        agent_profile_version: proposal.agent_profile_version,
        reason: proposal.reason, created_by_membership: @membership,
        created_by_user: @membership.user, published_at: Time.current
      )
      AuditEvent.record!(
        action: "governed_policy.canary_published", source: :web, workspace: @workspace,
        actor: @membership.user, subject: publication,
        metadata: { "preview_digest" => preview.results_digest, "scope_kind" => proposal.scope_kind }
      )
      publication
    end
  rescue ActiveRecord::RecordNotUnique
    raise StalePreview, "This preview or canary scope was published concurrently. Review current policy."
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidChange, error.record.errors.full_messages.to_sentence
  end

  def rollback!(publication:, expected_publication_id:, reason:)
    GovernedPolicyPublication.transaction do
      GovernedPolicyResolver.lock_workspace!(@workspace)
      publication = @workspace.governed_policy_publications.find(publication.id)
      ensure_retained!(publication, "Publication evidence")
      ensure_retained!(publication.proposal, "Proposal evidence")
      current = latest_for_scope(publication.proposal)
      unless current&.id == Integer(expected_publication_id.to_s, 10) && current == publication && publication.successor.nil?
        raise StalePreview, "The canary changed before rollback. Review current policy."
      end
      proposal = publication.proposal
      rollback = @workspace.governed_policy_publications.create!(
        proposal:, supersedes_publication: publication, action: "rollback",
        resolution_contract_version: proposal.prior_resolution_contract_version,
        agent_profile_version: proposal.prior_agent_profile_version,
        reason: bounded_reason(reason), created_by_membership: @membership,
        created_by_user: @membership.user, published_at: Time.current
      )
      AuditEvent.record!(
        action: "governed_policy.rolled_back", source: :web, workspace: @workspace,
        actor: @membership.user, subject: rollback,
        metadata: { "superseded_publication_id" => publication.id }
      )
      rollback
    end
  rescue ArgumentError, TypeError
    raise StalePreview, "The canary changed before rollback. Review current policy."
  rescue ActiveRecord::RecordNotUnique
    raise StalePreview, "The canary was rolled back concurrently. Review current policy."
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidChange, error.record.errors.full_messages.to_sentence
  end

  private
    def authorize!
      raise Current::RoleAccessDenied unless @membership.can_configure_agents?
    end

    def scoped_proposal(proposal)
      @workspace.governed_policy_proposals.find(proposal.id)
    end

    def validate_family_profile!(family, profile)
      expected = profile.crew_template.support? ? "support_resolution" : "customer_success_intervention"
      raise InvalidChange, "Contract and crew profile do not govern the same work." unless family.family_key == expected
    end

    def scoped_subjects!(kind, ids, profile)
      raise InvalidChange, "Choose an explicit supported canary scope." unless GovernedPolicyProposal::SCOPE_KINDS.include?(kind)
      values = Array(ids).compact_blank.map { |id| Integer(id.to_s, 10) }.uniq.sort
      raise InvalidChange, "Choose between 1 and #{MAX_SUBJECTS} retained subjects." unless values.size.in?(1..MAX_SUBJECTS)
      relation = case kind
      when "support_case"
        @workspace.support_cases.where(id: values).where.not(status: "closed")
      when "account"
        @workspace.accounts.where(id: values)
      when "agent_profile"
        raise InvalidChange, "A crew-profile canary must select this one bounded profile." unless values == [ profile.id ]
        @workspace.agent_profiles.where(id: values)
      end
      records = relation.order(:id).to_a
      raise InvalidChange, "One or more canary records are unavailable or not current." unless records.map(&:id) == values
      records
    rescue ArgumentError, TypeError
      raise InvalidChange, "Canary record IDs are invalid."
    end

    def build_contract_version!(family, attributes)
      values = normalized_contract(attributes)
      family.versions.create!(
        workspace: @workspace, version_number: family.versions.maximum(:version_number).to_i + 1,
        **values, created_by_membership: @membership, created_by_user: @membership.user
      )
    end

    def normalized_contract(attributes)
      values = attributes.to_h.symbolize_keys.slice(*CONTRACT_FIELDS)
      submitted = values.fetch(:evidence_freshness_days, {}).to_h.stringify_keys
      values[:required_claim_categories] = Array(values[:required_claim_categories]).compact_blank.map(&:to_s).uniq.sort
      values[:mandatory_review_checks] = Array(values[:mandatory_review_checks]).compact_blank.map(&:to_s).uniq.sort
      values[:evidence_freshness_days] = ResolutionContractVersion::SOURCE_KINDS.keys.to_h do |key|
        [ key, Integer(submitted.fetch(key).to_s, 10) ]
      end
      values[:execution_budget_units] = Integer(values[:execution_budget_units].to_s, 10)
      raise InvalidChange, "A governed execution budget must allow positive input and output limits." if
        values[:execution_budget_units] < 2
      values[:missing_items_block] = ActiveModel::Type::Boolean.new.cast(values[:missing_items_block])
      values
    rescue KeyError, ArgumentError, TypeError
      raise InvalidChange, "Contract policy fields are incomplete or invalid."
    end

    def build_profile_version!(profile, prior, attributes)
      submitted = attributes.to_h.symbolize_keys
      values = submitted.slice(*PROFILE_POLICY_FIELDS)
      values[:isolation_policy] = prior.isolation_policy unless submitted.key?(:isolation_policy)
      values[:fallback_profile_keys] = Array(values[:fallback_profile_keys]).compact_blank.map(&:to_s).uniq
      %i[timeout_seconds max_steps max_tool_calls].each { |key| values[key] = Integer(values[key].to_s, 10) }
      profile.versions.create!(
        workspace: @workspace, version_number: profile.versions.maximum(:version_number).to_i + 1,
        instructions: prior.instructions, allowed_tools: prior.allowed_tools, memory_required: prior.memory_required,
        **values, created_by_membership: @membership, created_by_user: @membership.user
      )
    rescue KeyError, ArgumentError, TypeError
      raise InvalidChange, "Runtime, isolation, fallback, review, and budget fields are incomplete or invalid."
    end

    def source_snapshot(proposal)
      {
        "proposal" => proposal_snapshot(proposal),
        "as_of_date" => Time.current.utc.to_date.iso8601,
        "subjects" => proposal.subjects.includes(:support_case, :account, :agent_profile).map { |item| subject_snapshot(item) },
        "memberships" => @workspace.memberships.order(:id).pluck(:id, :user_id, :role, :updated_at).map do |id, user_id, role, updated_at|
          { "id" => id, "role" => role, "updated_at" => timestamp(updated_at), "user_id" => user_id }
        end,
        "runtime_installations" => @workspace.runtime_installations.ordered.map { |runtime| runtime_snapshot(runtime) },
        "retained_records" => retained_records(proposal),
        "scope_publications" => scope_publications(proposal)
      }
    end

    def proposal_snapshot(proposal)
      {
        "id" => proposal.id,
        "family_current_version_id" => proposal.resolution_contract_family.reload.current_version_id,
        "profile_current_version_id" => proposal.agent_profile.reload.current_version_id,
        "prior_contract" => contract_snapshot(proposal.prior_resolution_contract_version),
        "candidate_contract" => contract_snapshot(proposal.resolution_contract_version),
        "prior_profile" => profile_snapshot(proposal.prior_agent_profile_version),
        "candidate_profile" => profile_snapshot(proposal.agent_profile_version)
      }
    end

    def subject_snapshot(item)
      record = item.subject
      values = { "id" => record.id, "kind" => item.subject_kind, "updated_at" => timestamp(record.updated_at) }
      values["status"] = record.status if record.respond_to?(:status)
      values
    end

    def contract_snapshot(version)
      CONTRACT_FIELDS.to_h { |field| [ field.to_s, version.public_send(field) ] }.merge("id" => version.id)
    end

    def profile_snapshot(version)
      PROFILE_POLICY_FIELDS.to_h { |field| [ field.to_s, version.public_send(field) ] }.merge(
        "id" => version.id, "allowed_tools" => version.allowed_tools
      )
    end

    def runtime_snapshot(runtime)
      %w[id updated_at detection_key adapter_key approved health_status compatibility_status capabilities profile_keys
        allowed_role_keys allowed_tools allowed_data_classes max_timeout_seconds max_steps max_tool_calls
        max_input_units max_output_units execution_mode].to_h do |field|
        value = runtime.public_send(field)
        [ field, value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) ? timestamp(value) : value ]
      end
    end

    def retained_records(proposal)
      task_ids = subject_task_ids(proposal)
      tasks = @workspace.crew_tasks.where(id: task_ids).includes(support_case: { conversation: :contact }).order(:id).map do |task|
        {
          "id" => task.id, "support_case_id" => task.support_case_id, "account_id" => task.account_id,
          "resolved_account_id" => task.account_id || task.support_case&.conversation&.contact&.account_id,
          "agent_profile_id" => task.assigned_agent_profile_id
        }
      end
      artifacts = @workspace.crew_artifacts.where(crew_task_id: task_ids).order(:id).map do |artifact|
        artifact.attributes.slice(
          "id", "crew_task_id", "resolution_contract_version_id", "material_claims", "policy_checks",
          "contract_result_state", "contract_blockers", "payload_digest", "created_at"
        ).transform_values { |value| value.respond_to?(:iso8601) ? timestamp(value) : value }
      end
      runs = @workspace.execution_runs.where(crew_task_id: task_ids).order(:id).map do |run|
        run.attributes.slice("id", "crew_task_id", "agent_profile_version_id", "runtime_installation_id",
          "selected_runtime_profile_key", "runtime_selection_reason", "input_units", "output_units", "status", "updated_at")
          .transform_values { |value| value.respond_to?(:iso8601) ? timestamp(value) : value }
      end
      { "tasks" => tasks, "artifacts" => artifacts, "runs" => runs }
    end

    def subject_task_ids(proposal)
      subjects = proposal.subjects.includes(support_case: { conversation: :contact }).to_a
      case_ids = subjects.filter_map(&:support_case_id)
      account_ids = subjects.filter_map(&:account_id)
      profile_ids = subjects.filter_map(&:agent_profile_id)
      account_case_ids = @workspace.support_cases.joins(conversation: :contact)
        .where(contacts: { account_id: account_ids }).pluck(:id)
      @workspace.crew_tasks.where(
        "support_case_id IN (?) OR account_id IN (?) OR assigned_agent_profile_id IN (?)",
        case_ids + account_case_ids, account_ids, profile_ids
      ).pluck(:id)
    end

    def scope_publications(proposal)
      publications_for_scope(proposal).order(:id)
        .pluck(:id, :action, :resolution_contract_version_id, :agent_profile_version_id)
    end

    def preview_results(proposal, snapshot)
      records = snapshot.fetch("retained_records")
      old_routing = routing_decision(proposal.prior_agent_profile_version)
      proposed_routing = routing_decision(proposal.agent_profile_version)
      proposal.subjects.includes(:support_case, :account, :agent_profile).map do |item|
        facts = typed_facts(item, records, snapshot.fetch("runtime_installations"))
        old_decision = decision(
          proposal.prior_resolution_contract_version, proposal.prior_agent_profile_version, facts,
          as_of_date: snapshot.fetch("as_of_date"), routing: old_routing
        )
        proposed_decision = decision(
          proposal.resolution_contract_version, proposal.agent_profile_version, facts,
          as_of_date: snapshot.fetch("as_of_date"), routing: proposed_routing
        )
        changes = %w[grounding quality_review routing fallback budget].select do |key|
          old_decision.fetch(key) != proposed_decision.fetch(key)
        end
        {
          "subject_kind" => item.subject_kind, "subject_id" => item.subject.id,
          "old_decision" => old_decision, "proposed_decision" => proposed_decision,
          "changes" => changes, "facts" => facts,
          "result" => changes.empty? ? "no_change" : "changed"
        }
      end.sort_by { |result| [ result.fetch("subject_kind"), result.fetch("subject_id") ] }
    end

    def typed_facts(item, records, runtimes)
      tasks = records.fetch("tasks").select do |task|
        case item.subject_kind
        when "support_case" then task.fetch("support_case_id") == item.subject.id
        when "account" then task.fetch("resolved_account_id") == item.subject.id
        when "agent_profile" then task.fetch("agent_profile_id") == item.subject.id
        end
      end
      task_ids = tasks.pluck("id")
      runs = records.fetch("runs").select { |run| task_ids.include?(run.fetch("crew_task_id")) }
      artifacts = records.fetch("artifacts").select { |artifact| task_ids.include?(artifact.fetch("crew_task_id")) }
      evidence = artifacts.flat_map { |artifact| artifact.fetch("material_claims").flat_map { |claim| claim.fetch("evidence") } }
      [
        fact("subject.kind", "string", item.subject_kind),
        fact("subject.id", "integer", item.subject.id),
        fact("artifact.count", "integer", artifacts.size),
        fact("claim.categories", "string_list", artifacts.flat_map { |artifact| artifact.fetch("material_claims").pluck("category") }.uniq.sort),
        fact("claim.blocker_count", "integer", artifacts.sum { |artifact| artifact.fetch("contract_blockers").size }),
        fact("evidence.records", "evidence_list", evidence.sort_by { |item| [ item.fetch("kind"), item.fetch("locator") ] }),
        fact("usage.observed_units", "integer", runs.sum { |run| run.fetch("input_units") + run.fetch("output_units") }),
        fact("runtime.installations", "runtime_list", runtimes)
      ]
    end

    def fact(key, type, value)
      { "key" => key, "type" => type, "value" => value }
    end

    def decision(contract, profile, facts, as_of_date:, routing:)
      values = facts.index_by { |fact| fact.fetch("key") }
      categories = values.fetch("claim.categories").fetch("value")
      missing = contract.required_claim_categories - categories
      evidence_blocked = values.fetch("evidence.records").fetch("value").any? do |evidence|
        evidence.fetch("status") != "available" || evidence_stale?(evidence, contract, as_of_date)
      end
      used = values.fetch("usage.observed_units").fetch("value")
      grounding = if missing.empty? && !evidence_blocked
        "allowed"
      elsif contract.missing_items_block?
        "blocked"
      else
        "needs_human"
      end
      {
        "grounding" => grounding,
        "quality_review" => {
          "requirement" => profile.review_policy,
          "checks" => contract.mandatory_review_checks,
          "changed_blocker" => values.fetch("claim.blocker_count").fetch("value").positive?
        },
        "routing" => routing.fetch("eligibility"),
        "fallback" => routing.fetch("fallback"),
        "budget" => {
          "result" => used <= contract.execution_budget_units ? "within_budget" : "over_budget",
          "used_units" => used, "limit_units" => contract.execution_budget_units
        }
      }
    end

    def routing_decision(profile)
      selection = RuntimeRouter.resolve!(workspace: @workspace, profile_version: profile)
      { "eligibility" => "eligible", "fallback" => selection.reason == "fallback" ? selection.profile_key : "not_used" }
    rescue RuntimeRouter::NoCompatibleRuntime => error
      { "eligibility" => "denied", "fallback" => "incompatible:#{error.message.split('.').first}" }
    end

    def evidence_stale?(evidence, contract, as_of_date)
      observed = Time.iso8601(evidence.fetch("observed_at").to_s).to_date
      observed + contract.evidence_freshness_days.fetch(evidence.fetch("kind")) < Date.iso8601(as_of_date)
    rescue ArgumentError, TypeError
      true
    end

    def ensure_sources_available!(proposal)
      proposal.subjects.each do |item|
        record = item.subject
        unavailable = record.nil? || (record.is_a?(SupportCase) && record.status_closed?)
        raise UnavailableSource, "A retained canary record is unavailable or no longer current." if unavailable
      end
    end

    def validate_current_security!(proposal)
      unless proposal.resolution_contract_family.current_version_id == proposal.prior_resolution_contract_version_id &&
          proposal.agent_profile.current_version_id == proposal.prior_agent_profile_version_id &&
          proposal.resolution_contract_version.mandatory_review_checks.include?("human_authority_preserved")
        raise StalePreview, "Current policy or security rules changed. Preview the proposal again."
      end
    end

    def latest_for_scope(proposal)
      publications_for_scope(proposal).order(id: :desc).first
    end

    def publications_for_scope(proposal)
      signature = scope_signature(proposal)
      proposal_ids = @workspace.governed_policy_proposals
        .where(
          scope_kind: proposal.scope_kind,
          resolution_contract_family_id: proposal.resolution_contract_family_id,
          agent_profile_id: proposal.agent_profile_id
        )
        .includes(:subjects)
        .select { |candidate| scope_signature(candidate) == signature }
        .map(&:id)
      @workspace.governed_policy_publications.where(governed_policy_proposal_id: proposal_ids)
    end

    def scope_signature(proposal)
      proposal.subjects.map do |subject|
        [ subject.subject_kind, subject.support_case_id, subject.account_id, subject.agent_profile_id ]
      end.sort
    end

    def bounded_reason(value)
      reason = value.to_s.strip
      raise InvalidChange, "Give a reason of 500 bytes or less." unless reason.bytesize.in?(1..500)
      reason
    end

    def digest(value)
      self.class.digest(value)
    end

    def ensure_retained!(record, label)
      raise UnavailableSource, "#{label} expired under the Workspace retention policy." if record.expired_at?
    end

    def timestamp(value)
      value&.iso8601(6)
    end
end
