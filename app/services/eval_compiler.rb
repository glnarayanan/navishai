class EvalCompiler
  VERSION = "support-contract-v1"

  def self.call(scenario:, membership:, version_id:, checks:)
    scenario.corpus.with_lock do
      scenario.corpus.authorize_writer!(membership)
      scenario.reload
      version = scenario.current_version
      raise EvalCase::Invalid, "Compile the current approved, unexpired scenario with current document evidence." unless version.id.to_s == version_id.to_s && version.approved? && !version.expired? && !version.stale? && !scenario.corpus.eval_definitions_expired?
      expected = version.requirements.flat_map { |kind, statements| statements.each_index.map { |index| [ kind, index ] } }.sort
      valid = checks.is_a?(Array) && checks.size.between?(1, 100) && checks.all? { |check| check.is_a?(Hash) && ScenarioVersion::REQUIREMENT_TYPES.include?(check["requirement_kind"]) && check["requirement_index"].to_s.match?(/\A\d+\z/) }
      actual = valid && checks.map { |check| [ check["requirement_kind"], check["requirement_index"].to_i ] }.sort
      raise EvalCase::Invalid, "Every contract statement needs exactly one grader and source reference." unless valid && actual == expected
      bindings = checks.map do |check|
        { grader_version: scenario.corpus.grader_versions.find(check["grader_version_id"]), scenario_evidence: version.scenario_evidence.find(check["scenario_evidence_id"]),
          requirement_kind: check["requirement_kind"], requirement_index: check["requirement_index"].to_i }
      end.sort_by { |binding| [ binding[:requirement_kind], binding[:requirement_index] ] }
      digest = Digest::SHA256.hexdigest([ VERSION, version.latest_review.id, bindings.map { |binding| [ binding[:requirement_kind], binding[:requirement_index], binding[:grader_version].id, binding[:scenario_evidence].id ] } ].to_json)
      existing = scenario.corpus.eval_cases.find_by(scenario_version: version, definition_digest: digest)
      return existing if existing

      item = scenario.corpus.eval_cases.create!(workspace: scenario.workspace, scenario_version: version, scenario_review: version.latest_review,
        compiled_by: membership.user, number: (scenario.corpus.eval_cases.where(scenario_version: version).maximum(:number) || 0) + 1,
        compiler_version: VERSION, definition_digest: digest, contract: version.requirements, created_at: Time.current)
      bindings.each do |binding|
        item.eval_case_checks.create!(workspace: scenario.workspace, corpus: scenario.corpus, scenario_version: version,
          **binding)
      end
      AuditEvent.record!(action: "eval.compiled", source: :web, workspace: scenario.workspace, actor: membership.user, subject: item, metadata: { version: item.number })
      item
    end
  end
end
