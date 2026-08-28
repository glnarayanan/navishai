class CreateCustomerSuccessInterventions < ActiveRecord::Migration[8.1]
  def up
    create_interventions
    create_outcome_reviews
    protect_records
    extend_content_expiry
  end

  def down
    restore_content_expiry
    drop_table :customer_success_intervention_outcome_reviews
    drop_table :customer_success_interventions
    execute "DROP FUNCTION IF EXISTS protect_customer_success_outcome_review() CASCADE"
    execute "DROP FUNCTION IF EXISTS protect_customer_success_intervention() CASCADE"
  end

  private
    def create_interventions
      create_table :customer_success_interventions do |t|
        t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
        t.bigint :account_id, null: false
        t.bigint :account_health_assessment_id, null: false
        t.bigint :account_risk_investigation_id
        t.bigint :proposing_crew_artifact_id, null: false
        t.bigint :accountable_membership_id, null: false
        t.bigint :proposed_by_membership_id, null: false
        t.string :status, null: false, default: "proposed"
        t.jsonb :supporting_evidence, null: false, default: []
        t.text :expected_observable_change, null: false
        t.date :target_on, null: false
        t.text :reason, null: false
        t.datetime :proposed_at, null: false
        t.bigint :approved_by_membership_id
        t.datetime :approved_at
        t.bigint :completed_by_membership_id
        t.datetime :completed_at
        t.bigint :abandoned_by_membership_id
        t.datetime :abandoned_at
        t.text :abandonment_reason
        t.timestamps
      end

      add_index :customer_success_interventions, [ :workspace_id, :id ], unique: true,
        name: "index_cs_interventions_on_workspace_id_and_id"
      add_index :customer_success_interventions, [ :workspace_id, :account_id, :status, :target_on ],
        name: "index_cs_interventions_for_account_work"
      add_index :customer_success_interventions, :proposing_crew_artifact_id, unique: true,
        name: "index_cs_interventions_on_proposing_artifact"
      add_foreign_key :customer_success_interventions, :accounts,
        column: [ :workspace_id, :account_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_cs_interventions_account"
      add_foreign_key :customer_success_interventions, :account_health_assessments,
        column: [ :workspace_id, :account_health_assessment_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_cs_interventions_assessment"
      add_foreign_key :customer_success_interventions, :account_risk_investigations,
        column: [ :workspace_id, :account_risk_investigation_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_cs_interventions_investigation"
      add_foreign_key :customer_success_interventions, :crew_artifacts,
        column: [ :workspace_id, :proposing_crew_artifact_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_cs_interventions_artifact"
      %i[accountable proposed_by approved_by completed_by abandoned_by].each do |actor|
        add_foreign_key :customer_success_interventions, :memberships,
          column: [ :workspace_id, "#{actor}_membership_id" ], primary_key: [ :workspace_id, :id ],
          name: "fk_cs_interventions_#{actor}"
      end

      add_check_constraint :customer_success_interventions,
        "status IN ('proposed', 'approved', 'completed', 'abandoned', 'reviewed')",
        name: "customer_success_interventions_status"
      add_check_constraint :customer_success_interventions,
        "jsonb_typeof(supporting_evidence) = 'array' AND jsonb_array_length(supporting_evidence) BETWEEN 1 AND 20",
        name: "customer_success_interventions_evidence"
      add_check_constraint :customer_success_interventions,
        "octet_length(expected_observable_change) BETWEEN 1 AND 2000 AND octet_length(reason) BETWEEN 1 AND 1000 AND " \
        "(abandonment_reason IS NULL OR octet_length(abandonment_reason) BETWEEN 1 AND 1000)",
        name: "customer_success_interventions_content"
      state_constraint = <<~SQL.squish
        (status = 'proposed' AND approved_by_membership_id IS NULL AND approved_at IS NULL AND
          completed_by_membership_id IS NULL AND completed_at IS NULL AND
          abandoned_by_membership_id IS NULL AND abandoned_at IS NULL AND abandonment_reason IS NULL) OR
        (status = 'approved' AND approved_by_membership_id IS NOT NULL AND approved_at IS NOT NULL AND
          completed_by_membership_id IS NULL AND completed_at IS NULL AND
          abandoned_by_membership_id IS NULL AND abandoned_at IS NULL AND abandonment_reason IS NULL) OR
        (status IN ('completed', 'reviewed') AND approved_by_membership_id IS NOT NULL AND approved_at IS NOT NULL AND
          completed_by_membership_id IS NOT NULL AND completed_at IS NOT NULL AND
          abandoned_by_membership_id IS NULL AND abandoned_at IS NULL AND abandonment_reason IS NULL) OR
        (status = 'abandoned' AND completed_by_membership_id IS NULL AND completed_at IS NULL AND
          abandoned_by_membership_id IS NOT NULL AND abandoned_at IS NOT NULL AND abandonment_reason IS NOT NULL)
      SQL
      add_check_constraint :customer_success_interventions, state_constraint,
        name: "customer_success_interventions_state"
    end

    def create_outcome_reviews
      create_table :customer_success_intervention_outcome_reviews do |t|
        t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
        t.bigint :customer_success_intervention_id, null: false
        t.bigint :before_account_health_assessment_id, null: false
        t.bigint :after_account_health_assessment_id, null: false
        t.bigint :reviewed_by_membership_id, null: false
        t.jsonb :before_snapshot, null: false
        t.jsonb :after_snapshot, null: false
        t.jsonb :changed_facts, null: false, default: []
        t.jsonb :unchanged_facts, null: false, default: []
        t.text :uncertainty, null: false
        t.text :observed_association, null: false
        t.datetime :reviewed_at, null: false
        t.timestamps
      end

      add_index :customer_success_intervention_outcome_reviews,
        [ :workspace_id, :id ], unique: true, name: "index_cs_outcome_reviews_on_workspace_id_and_id"
      add_index :customer_success_intervention_outcome_reviews,
        :customer_success_intervention_id, unique: true, name: "index_cs_outcome_reviews_on_intervention"
      add_foreign_key :customer_success_intervention_outcome_reviews, :customer_success_interventions,
        column: [ :workspace_id, :customer_success_intervention_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_cs_outcome_reviews_intervention"
      add_foreign_key :customer_success_intervention_outcome_reviews, :account_health_assessments,
        column: [ :workspace_id, :before_account_health_assessment_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_cs_outcome_reviews_before_assessment"
      add_foreign_key :customer_success_intervention_outcome_reviews, :account_health_assessments,
        column: [ :workspace_id, :after_account_health_assessment_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_cs_outcome_reviews_after_assessment"
      add_foreign_key :customer_success_intervention_outcome_reviews, :memberships,
        column: [ :workspace_id, :reviewed_by_membership_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_cs_outcome_reviews_reviewer"
      add_check_constraint :customer_success_intervention_outcome_reviews,
        "before_account_health_assessment_id <> after_account_health_assessment_id",
        name: "customer_success_outcome_reviews_assessments"
      add_check_constraint :customer_success_intervention_outcome_reviews,
        "jsonb_typeof(before_snapshot) = 'object' AND jsonb_typeof(after_snapshot) = 'object' AND " \
        "octet_length(before_snapshot::text) <= 131072 AND octet_length(after_snapshot::text) <= 131072 AND " \
        "jsonb_typeof(changed_facts) = 'array' AND jsonb_array_length(changed_facts) <= 50 AND " \
        "jsonb_typeof(unchanged_facts) = 'array' AND jsonb_array_length(unchanged_facts) <= 50",
        name: "customer_success_outcome_reviews_snapshots"
      add_check_constraint :customer_success_intervention_outcome_reviews,
        "octet_length(uncertainty) BETWEEN 1 AND 2000 AND octet_length(observed_association) BETWEEN 1 AND 2000",
        name: "customer_success_outcome_reviews_content"
    end

    def protect_records
      execute <<~SQL
        CREATE FUNCTION protect_customer_success_intervention()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'TRUNCATE' THEN
            RAISE EXCEPTION 'customer success interventions cannot be truncated';
          END IF;
          IF TG_OP = 'DELETE' THEN
            IF NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            RAISE EXCEPTION 'customer success interventions cannot be deleted';
          END IF;
          IF ROW(
            NEW.workspace_id, NEW.account_id, NEW.account_health_assessment_id,
            NEW.account_risk_investigation_id, NEW.proposing_crew_artifact_id,
            NEW.accountable_membership_id, NEW.proposed_by_membership_id,
            NEW.supporting_evidence, NEW.expected_observable_change, NEW.target_on,
            NEW.reason, NEW.proposed_at, NEW.created_at
          ) IS DISTINCT FROM ROW(
            OLD.workspace_id, OLD.account_id, OLD.account_health_assessment_id,
            OLD.account_risk_investigation_id, OLD.proposing_crew_artifact_id,
            OLD.accountable_membership_id, OLD.proposed_by_membership_id,
            OLD.supporting_evidence, OLD.expected_observable_change, OLD.target_on,
            OLD.reason, OLD.proposed_at, OLD.created_at
          ) THEN
            RAISE EXCEPTION 'customer success intervention provenance is immutable';
          END IF;
          IF OLD.status = 'proposed' AND NEW.status = 'approved' THEN
            IF NEW.approved_by_membership_id IS NULL OR NEW.approved_at IS NULL OR
                NEW.completed_by_membership_id IS NOT NULL OR NEW.completed_at IS NOT NULL OR
                NEW.abandoned_by_membership_id IS NOT NULL OR NEW.abandoned_at IS NOT NULL OR
                NEW.abandonment_reason IS NOT NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention approval';
            END IF;
          ELSIF OLD.status = 'proposed' AND NEW.status = 'abandoned' THEN
            IF NEW.approved_by_membership_id IS NOT NULL OR NEW.approved_at IS NOT NULL OR
                NEW.completed_by_membership_id IS NOT NULL OR NEW.completed_at IS NOT NULL OR
                NEW.abandoned_by_membership_id IS NULL OR NEW.abandoned_at IS NULL OR
                NEW.abandonment_reason IS NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention abandonment';
            END IF;
          ELSIF OLD.status = 'approved' AND NEW.status = 'completed' THEN
            IF ROW(NEW.approved_by_membership_id, NEW.approved_at) IS DISTINCT FROM
                ROW(OLD.approved_by_membership_id, OLD.approved_at) OR
                NEW.completed_by_membership_id IS NULL OR NEW.completed_at IS NULL OR
                NEW.abandoned_by_membership_id IS NOT NULL OR NEW.abandoned_at IS NOT NULL OR
                NEW.abandonment_reason IS NOT NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention completion';
            END IF;
          ELSIF OLD.status = 'approved' AND NEW.status = 'abandoned' THEN
            IF ROW(NEW.approved_by_membership_id, NEW.approved_at) IS DISTINCT FROM
                ROW(OLD.approved_by_membership_id, OLD.approved_at) OR
                NEW.completed_by_membership_id IS NOT NULL OR NEW.completed_at IS NOT NULL OR
                NEW.abandoned_by_membership_id IS NULL OR NEW.abandoned_at IS NULL OR
                NEW.abandonment_reason IS NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention abandonment';
            END IF;
          ELSIF OLD.status = 'completed' AND NEW.status = 'reviewed' THEN
            IF ROW(
                NEW.approved_by_membership_id, NEW.approved_at,
                NEW.completed_by_membership_id, NEW.completed_at
              ) IS DISTINCT FROM ROW(
                OLD.approved_by_membership_id, OLD.approved_at,
                OLD.completed_by_membership_id, OLD.completed_at
              ) OR NOT EXISTS (
                SELECT 1 FROM customer_success_intervention_outcome_reviews
                WHERE customer_success_intervention_id = NEW.id AND workspace_id = NEW.workspace_id
              ) THEN
              RAISE EXCEPTION 'invalid customer success intervention outcome review';
            END IF;
          ELSE
            RAISE EXCEPTION 'invalid customer success intervention transition';
          END IF;
          RETURN NEW;
        END;
        $$;
        CREATE TRIGGER customer_success_interventions_transition
          BEFORE UPDATE OR DELETE ON customer_success_interventions
          FOR EACH ROW EXECUTE FUNCTION protect_customer_success_intervention();
        CREATE TRIGGER customer_success_interventions_no_truncate
          BEFORE TRUNCATE ON customer_success_interventions
          FOR EACH STATEMENT EXECUTE FUNCTION protect_customer_success_intervention();

        CREATE FUNCTION protect_customer_success_outcome_review()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'TRUNCATE' THEN
            RAISE EXCEPTION 'customer success outcome reviews cannot be truncated';
          END IF;
          IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
            RETURN OLD;
          END IF;
          RAISE EXCEPTION 'customer success outcome reviews are append only';
        END;
        $$;
        CREATE TRIGGER customer_success_outcome_reviews_append_only
          BEFORE UPDATE OR DELETE ON customer_success_intervention_outcome_reviews
          FOR EACH ROW EXECUTE FUNCTION protect_customer_success_outcome_review();
        CREATE TRIGGER customer_success_outcome_reviews_no_truncate
          BEFORE TRUNCATE ON customer_success_intervention_outcome_reviews
          FOR EACH STATEMENT EXECUTE FUNCTION protect_customer_success_outcome_review();
      SQL
    end

    def extend_content_expiry
      execute <<~SQL
        ALTER FUNCTION expire_workspace_content(bigint, timestamp without time zone)
          RENAME TO expire_workspace_content_before_interventions;

        CREATE FUNCTION expire_workspace_content(target_workspace_id bigint, cutoff timestamp without time zone)
        RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
        SET search_path = public, pg_temp AS $$
        DECLARE
          affected integer;
          total integer;
        BEGIN
          total := expire_workspace_content_before_interventions(target_workspace_id, cutoff);
          LOCK TABLE customer_success_interventions, customer_success_intervention_outcome_reviews
            IN ACCESS EXCLUSIVE MODE;
          ALTER TABLE customer_success_interventions DISABLE TRIGGER USER;
          ALTER TABLE customer_success_intervention_outcome_reviews DISABLE TRIGGER USER;

          UPDATE customer_success_interventions AS interventions
          SET expected_observable_change = '[Expired by retention policy]',
              reason = '[Expired by retention policy]',
              abandonment_reason = CASE WHEN abandonment_reason IS NULL THEN NULL ELSE '[Expired by retention policy]' END,
              supporting_evidence = COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                  'kind', evidence->>'kind',
                  'label', '[Expired by retention policy]',
                  'locator', format(
                    'retention-expired://customer-success-interventions/%s/evidence/%s',
                    interventions.id, evidence_position
                  )
                ) ORDER BY evidence_position)
                FROM jsonb_array_elements(interventions.supporting_evidence)
                  WITH ORDINALITY AS evidence_items(evidence, evidence_position)
              ), '[]'::jsonb),
              updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND proposed_at < cutoff AND
            expected_observable_change <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE customer_success_intervention_outcome_reviews
          SET before_snapshot = '{"retention":"expired"}'::jsonb,
              after_snapshot = '{"retention":"expired"}'::jsonb,
              changed_facts = '[]'::jsonb,
              unchanged_facts = '[]'::jsonb,
              uncertainty = '[Expired by retention policy]',
              observed_association = '[Expired by retention policy]',
              updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND reviewed_at < cutoff AND
            before_snapshot <> '{"retention":"expired"}'::jsonb;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          ALTER TABLE customer_success_intervention_outcome_reviews ENABLE TRIGGER USER;
          ALTER TABLE customer_success_interventions ENABLE TRIGGER USER;
          RETURN total;
        END;
        $$;
        REVOKE ALL ON FUNCTION expire_workspace_content(bigint, timestamp without time zone) FROM PUBLIC;
      SQL
    end

    def restore_content_expiry
      execute <<~SQL
        DROP FUNCTION expire_workspace_content(bigint, timestamp without time zone);
        ALTER FUNCTION expire_workspace_content_before_interventions(bigint, timestamp without time zone)
          RENAME TO expire_workspace_content;
      SQL
    end
end
