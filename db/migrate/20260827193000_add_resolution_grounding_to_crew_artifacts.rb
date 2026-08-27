class AddResolutionGroundingToCrewArtifacts < ActiveRecord::Migration[8.1]
  def change
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION resolution_grounding_valid(required_facts jsonb, material_claims jsonb)
          RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT AS $$
          DECLARE
            claim jsonb;
            evidence jsonb;
            claim_key text;
            claim_keys text[] := ARRAY[]::text[];
            evidence_keys text[];
            required_fact jsonb;
          BEGIN
            IF jsonb_typeof(required_facts) <> 'array' OR jsonb_typeof(material_claims) <> 'array' THEN
              RETURN FALSE;
            END IF;
            FOR claim IN SELECT value FROM jsonb_array_elements(material_claims)
            LOOP
              IF jsonb_typeof(claim) <> 'object' OR
                 NOT claim ?& ARRAY['category','evidence','key','state','text'] OR
                 claim - ARRAY['category','evidence','key','state','text'] <> '{}'::jsonb OR
                 jsonb_typeof(claim->'key') <> 'string' OR
                 jsonb_typeof(claim->'category') <> 'string' OR
                 jsonb_typeof(claim->'state') <> 'string' OR
                 jsonb_typeof(claim->'text') <> 'string' OR
                 jsonb_typeof(claim->'evidence') <> 'array' OR
                 jsonb_array_length(claim->'evidence') > 20 OR
                 claim->>'key' !~ '^[a-z][a-z0-9_]{0,63}$' OR
                 octet_length(btrim(claim->>'text')) NOT BETWEEN 1 AND 4000 OR
                 claim->>'category' NOT IN ('customer_account_fact','product_technical_fact','policy_entitlement','promised_action_date') OR
                 claim->>'state' NOT IN ('supported','uncertain','conflicted','refused') THEN
                RETURN FALSE;
              END IF;
              claim_key := claim->>'key';
              IF claim_key = ANY(claim_keys) THEN
                RETURN FALSE;
              END IF;
              claim_keys := array_append(claim_keys, claim_key);
              evidence_keys := ARRAY[]::text[];
              FOR evidence IN SELECT value FROM jsonb_array_elements(claim->'evidence')
              LOOP
                IF jsonb_typeof(evidence) <> 'object' OR
                   NOT evidence ?& ARRAY['kind','locator','status','observed_at','valid_until','fresh_until'] OR
                   evidence - ARRAY['kind','locator','status','observed_at','valid_until','fresh_until'] <> '{}'::jsonb OR
                   jsonb_typeof(evidence->'kind') <> 'string' OR
                   jsonb_typeof(evidence->'locator') <> 'string' OR
                   jsonb_typeof(evidence->'status') <> 'string' OR
                   octet_length(btrim(evidence->>'locator')) NOT BETWEEN 1 AND 2000 OR
                   evidence->>'kind' NOT IN ('knowledge','conversation','case','account','health_signal','public_web','memory') OR
                   evidence->>'status' NOT IN ('available','stale','expired','deleted','unavailable','conflicted','not_yet_valid') OR
                   jsonb_typeof(evidence->'observed_at') NOT IN ('string','null') OR
                   jsonb_typeof(evidence->'valid_until') NOT IN ('string','null') OR
                   jsonb_typeof(evidence->'fresh_until') NOT IN ('string','null') THEN
                  RETURN FALSE;
                END IF;
                IF ((evidence->>'kind') || ':' || (evidence->>'locator')) = ANY(evidence_keys) THEN
                  RETURN FALSE;
                END IF;
                evidence_keys := array_append(evidence_keys, (evidence->>'kind') || ':' || (evidence->>'locator'));
              END LOOP;
              IF claim->>'state' <> 'refused' AND jsonb_array_length(claim->'evidence') = 0 THEN
                RETURN FALSE;
              END IF;
              IF claim->>'state' = 'supported' AND (
                   jsonb_array_length(claim->'evidence') = 0 OR
                   EXISTS (
                     SELECT 1 FROM jsonb_array_elements(claim->'evidence') item
                     WHERE item->>'status' <> 'available' OR
                           jsonb_typeof(item->'observed_at') <> 'string' OR
                           jsonb_typeof(item->'fresh_until') <> 'string'
                   )
                 ) THEN
                RETURN FALSE;
              END IF;
            END LOOP;
            FOR required_fact IN SELECT value FROM jsonb_array_elements(required_facts)
            LOOP
              IF jsonb_typeof(required_fact) <> 'string' OR
                 (required_fact #>> '{}') !~ '^[a-z][a-z0-9_]{0,63}$' OR
                 NOT ((required_fact #>> '{}') = ANY(claim_keys)) THEN
                RETURN FALSE;
              END IF;
            END LOOP;
            RETURN jsonb_array_length(required_facts) = cardinality(
              ARRAY(SELECT DISTINCT value #>> '{}' FROM jsonb_array_elements(required_facts))
            );
          EXCEPTION WHEN OTHERS THEN
            RETURN FALSE;
          END;
          $$;
        SQL
      end
      direction.down { execute "DROP FUNCTION IF EXISTS resolution_grounding_valid(jsonb, jsonb)" }
    end

    add_column :crew_artifacts, :schema_version, :integer, null: false, default: 1
    add_column :crew_artifacts, :resolution_contract_version_id, :bigint
    add_column :crew_artifacts, :required_facts, :jsonb, null: false, default: []
    add_column :crew_artifacts, :material_claims, :jsonb, null: false, default: []
    add_column :crew_artifacts, :proposed_actions, :jsonb, null: false, default: []
    add_column :crew_artifacts, :policy_checks, :jsonb, null: false, default: []
    add_column :crew_artifacts, :contract_result_state, :string
    add_column :crew_artifacts, :contract_blockers, :jsonb, null: false, default: []
    add_column :crew_artifacts, :contract_evaluated_at, :datetime

    add_index :crew_artifacts, :resolution_contract_version_id
    add_foreign_key :crew_artifacts, :resolution_contract_versions,
      column: [ :workspace_id, :resolution_contract_version_id ],
      primary_key: [ :workspace_id, :id ], name: "fk_crew_artifacts_resolution_contract"

    add_check_constraint :crew_artifacts, "schema_version IN (1, 2)",
      name: "crew_artifacts_schema_version"
    add_check_constraint :crew_artifacts,
      "contract_result_state IS NULL OR contract_result_state IN ('complete', 'blocked', 'needs_human')",
      name: "crew_artifacts_contract_result"
    add_check_constraint :crew_artifacts,
      "jsonb_typeof(required_facts) = 'array' AND jsonb_array_length(required_facts) <= 20 AND " \
      "jsonb_typeof(material_claims) = 'array' AND jsonb_array_length(material_claims) <= 20 AND " \
      "jsonb_typeof(proposed_actions) = 'array' AND jsonb_array_length(proposed_actions) <= 20 AND " \
      "jsonb_typeof(policy_checks) = 'array' AND jsonb_array_length(policy_checks) <= 4 AND " \
      "jsonb_typeof(contract_blockers) = 'array' AND jsonb_array_length(contract_blockers) <= 100",
      name: "crew_artifacts_resolution_collections"
    add_check_constraint :crew_artifacts,
      "resolution_grounding_valid(required_facts, material_claims)",
      name: "crew_artifacts_resolution_grounding"
    add_check_constraint :crew_artifacts,
      "(schema_version = 1 AND resolution_contract_version_id IS NULL AND contract_result_state IS NULL AND " \
      "contract_evaluated_at IS NULL AND jsonb_array_length(required_facts) = 0 AND " \
      "jsonb_array_length(material_claims) = 0 AND jsonb_array_length(proposed_actions) = 0 AND " \
      "jsonb_array_length(policy_checks) = 0 AND jsonb_array_length(contract_blockers) = 0) OR " \
      "(schema_version = 2 AND resolution_contract_version_id IS NOT NULL AND contract_result_state IS NOT NULL AND " \
      "contract_evaluated_at IS NOT NULL AND jsonb_array_length(required_facts) BETWEEN 1 AND 20 AND " \
      "jsonb_array_length(material_claims) BETWEEN 1 AND 20)",
      name: "crew_artifacts_resolution_shape"
  end
end
