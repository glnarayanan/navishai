class ExpireResolutionGroundingContent < ActiveRecord::Migration[8.1]
  OLD_UPDATE = <<~SQL.strip
    UPDATE crew_artifacts
    SET body = '[Expired by retention policy]', uncertainty = '[Expired by retention policy]', citations = '[]'::jsonb,
        conflicts = '[]'::jsonb, change_requests = '[]'::jsonb, payload_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
    WHERE workspace_id = target_workspace_id AND created_at < cutoff AND body <> '[Expired by retention policy]';
  SQL

  NEW_UPDATE = <<~SQL.strip
    UPDATE crew_artifacts AS artifacts
    SET body = '[Expired by retention policy]', uncertainty = '[Expired by retention policy]',
        citations = '[]'::jsonb, conflicts = '[]'::jsonb, change_requests = '[]'::jsonb,
        required_facts = CASE WHEN schema_version = 2 THEN COALESCE((
          SELECT jsonb_agg(to_jsonb('expired_claim_' || claim_position) ORDER BY claim_position)
          FROM jsonb_array_elements(artifacts.material_claims) WITH ORDINALITY AS claims(claim, claim_position)
          WHERE artifacts.required_facts ? (claim->>'key')
        ), '[]'::jsonb) ELSE required_facts END,
        material_claims = CASE WHEN schema_version = 2 THEN COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'key', 'expired_claim_' || claim_position,
            'category', claim->>'category',
            'text', '[Expired by retention policy]',
            'state', CASE
              WHEN jsonb_array_length(claim->'evidence') = 0 THEN 'refused'
              WHEN claim->>'state' = 'supported' THEN 'uncertain'
              ELSE claim->>'state'
            END,
            'evidence', COALESCE((
              SELECT jsonb_agg(jsonb_build_object(
                'kind', evidence->>'kind',
                'locator', format(
                  'retention-expired://crew-artifacts/%s/claims/%s/evidence/%s',
                  artifacts.id, claim_position, evidence_position
                ),
                'status', 'expired',
                'observed_at', NULL,
                'valid_until', NULL,
                'fresh_until', NULL
              ) ORDER BY evidence_position)
              FROM jsonb_array_elements(claim->'evidence') WITH ORDINALITY AS evidence_items(evidence, evidence_position)
            ), '[]'::jsonb)
          ) ORDER BY claim_position)
          FROM jsonb_array_elements(artifacts.material_claims) WITH ORDINALITY AS claims(claim, claim_position)
        ), '[]'::jsonb) ELSE material_claims END,
        proposed_actions = CASE WHEN schema_version = 2 THEN '[]'::jsonb ELSE proposed_actions END,
        contract_blockers = CASE WHEN schema_version = 2 THEN COALESCE((
          SELECT jsonb_agg(blocker || jsonb_build_object(
            'claim_key', NULL,
            'message', '[Expired by retention policy]',
            'remediation', '[Expired by retention policy]'
          ) ORDER BY blocker_position)
          FROM jsonb_array_elements(artifacts.contract_blockers) WITH ORDINALITY AS blockers(blocker, blocker_position)
        ), '[]'::jsonb) ELSE contract_blockers END,
        payload_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
    WHERE workspace_id = target_workspace_id AND created_at < cutoff AND (
      body <> '[Expired by retention policy]' OR uncertainty <> '[Expired by retention policy]' OR
      citations <> '[]'::jsonb OR conflicts <> '[]'::jsonb OR change_requests <> '[]'::jsonb OR
      (schema_version = 2 AND (
        proposed_actions <> '[]'::jsonb OR
        EXISTS (
          SELECT 1 FROM jsonb_array_elements(material_claims) AS claims(claim)
          WHERE claim->>'text' <> '[Expired by retention policy]' OR
            claim->>'key' NOT LIKE 'expired_claim_%' OR
            EXISTS (
              SELECT 1 FROM jsonb_array_elements(claim->'evidence') AS evidence_items(evidence)
              WHERE evidence->>'locator' NOT LIKE 'retention-expired://crew-artifacts/%'
            )
        ) OR
        EXISTS (
          SELECT 1 FROM jsonb_array_elements(contract_blockers) AS blockers(blocker)
          WHERE blocker->>'message' <> '[Expired by retention policy]' OR
            blocker->>'remediation' <> '[Expired by retention policy]' OR
            blocker->'claim_key' <> 'null'::jsonb
        )
      ))
    );
  SQL

  def up
    replace_expiry_update(OLD_UPDATE, NEW_UPDATE)
  end

  def down
    replace_expiry_update(NEW_UPDATE, OLD_UPDATE)
  end

  private
    def replace_expiry_update(previous, replacement)
      definition = select_value(<<~SQL)
        SELECT pg_get_functiondef(
          'expire_workspace_content(bigint, timestamp without time zone)'::regprocedure
        )
      SQL
      previous = previous.lines.map { |line| "  #{line}" }.join
      replacement = replacement.lines.map { |line| "  #{line}" }.join
      unless definition.include?(previous)
        raise ActiveRecord::MigrationError, "crew artifact expiry update has an unexpected definition"
      end

      execute definition.sub(previous, replacement)
    end
end
