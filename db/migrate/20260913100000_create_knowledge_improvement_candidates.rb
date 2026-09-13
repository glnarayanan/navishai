class CreateKnowledgeImprovementCandidates < ActiveRecord::Migration[8.1]
  def up
    create_candidates
    protect_records
    extend_content_expiry
  end

  def down
    restore_content_expiry
    drop_table :knowledge_improvement_candidates
    execute "DROP FUNCTION IF EXISTS protect_knowledge_improvement_candidate() CASCADE"
  end

  private
    def create_candidates
      create_table :knowledge_improvement_candidates do |t|
        t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
        t.bigint :source_crew_artifact_id
        t.bigint :support_case_id
        t.bigint :knowledge_source_id
        t.string :reason_code, null: false
        t.string :title, null: false
        t.text :detail, null: false
        t.string :status, null: false, default: "open"
        t.bigint :created_by_membership_id, null: false
        t.datetime :opened_at, null: false
        t.bigint :triaged_by_membership_id
        t.datetime :triaged_at
        t.text :triage_note
        t.bigint :assigned_to_membership_id
        t.bigint :assigned_by_membership_id
        t.datetime :assigned_at
        t.bigint :resolved_knowledge_source_id
        t.bigint :resolved_knowledge_source_version_id
        t.bigint :resolved_by_membership_id
        t.datetime :resolved_at
        t.bigint :dismissed_by_membership_id
        t.datetime :dismissed_at
        t.text :dismissal_reason
        t.timestamps
      end

      add_index :knowledge_improvement_candidates, [ :workspace_id, :id ], unique: true,
        name: "index_knowledge_improvement_candidates_on_workspace_and_id"
      add_index :knowledge_improvement_candidates, [ :workspace_id, :status, :id ],
        name: "index_knowledge_improvement_candidates_for_queue"
      add_index :knowledge_improvement_candidates, :source_crew_artifact_id, unique: true,
        where: "source_crew_artifact_id IS NOT NULL",
        name: "index_knowledge_improvement_candidates_on_artifact"
      add_index :knowledge_improvement_candidates, [ :workspace_id, :knowledge_source_id ], unique: true,
        where: "knowledge_source_id IS NOT NULL AND status IN ('open', 'triaged', 'assigned')",
        name: "index_knowledge_improvement_candidates_open_source"
      add_foreign_key :knowledge_improvement_candidates, :crew_artifacts,
        column: [ :workspace_id, :source_crew_artifact_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_knowledge_improvement_candidates_artifact"
      add_foreign_key :knowledge_improvement_candidates, :support_cases,
        column: [ :workspace_id, :support_case_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_knowledge_improvement_candidates_case"
      add_foreign_key :knowledge_improvement_candidates, :knowledge_sources,
        column: [ :workspace_id, :knowledge_source_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_knowledge_improvement_candidates_source"
      add_foreign_key :knowledge_improvement_candidates, :knowledge_sources,
        column: [ :workspace_id, :resolved_knowledge_source_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_knowledge_improvement_candidates_resolved_source"
      add_foreign_key :knowledge_improvement_candidates, :knowledge_source_versions,
        column: [ :workspace_id, :resolved_knowledge_source_version_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_knowledge_improvement_candidates_resolved_version"
      %i[created_by triaged_by assigned_to assigned_by resolved_by dismissed_by].each do |actor|
        add_foreign_key :knowledge_improvement_candidates, :memberships,
          column: [ :workspace_id, "#{actor}_membership_id" ], primary_key: [ :workspace_id, :id ],
          name: "fk_knowledge_improvement_candidates_#{actor}"
      end

      add_check_constraint :knowledge_improvement_candidates,
        "reason_code IN ('missing_knowledge', 'stale', 'deleted', 'retired', 'failed_sync')",
        name: "knowledge_improvement_candidates_reason"
      add_check_constraint :knowledge_improvement_candidates,
        "status IN ('open', 'triaged', 'assigned', 'resolved', 'dismissed')",
        name: "knowledge_improvement_candidates_status"
      add_check_constraint :knowledge_improvement_candidates,
        "octet_length(title) BETWEEN 1 AND 200 AND octet_length(detail) BETWEEN 1 AND 2000 AND " \
        "(triage_note IS NULL OR octet_length(triage_note) BETWEEN 1 AND 1000) AND " \
        "(dismissal_reason IS NULL OR octet_length(dismissal_reason) BETWEEN 1 AND 1000)",
        name: "knowledge_improvement_candidates_content"
      add_check_constraint :knowledge_improvement_candidates,
        "(source_crew_artifact_id IS NOT NULL AND support_case_id IS NOT NULL) OR knowledge_source_id IS NOT NULL",
        name: "knowledge_improvement_candidates_origin"
      state_constraint = <<~SQL.squish
        (status = 'open' AND triaged_by_membership_id IS NULL AND triaged_at IS NULL AND triage_note IS NULL AND
          assigned_to_membership_id IS NULL AND assigned_by_membership_id IS NULL AND assigned_at IS NULL AND
          resolved_knowledge_source_id IS NULL AND resolved_knowledge_source_version_id IS NULL AND
          resolved_by_membership_id IS NULL AND resolved_at IS NULL AND
          dismissed_by_membership_id IS NULL AND dismissed_at IS NULL AND dismissal_reason IS NULL) OR
        (status = 'triaged' AND triaged_by_membership_id IS NOT NULL AND triaged_at IS NOT NULL AND triage_note IS NOT NULL AND
          assigned_to_membership_id IS NULL AND assigned_by_membership_id IS NULL AND assigned_at IS NULL AND
          resolved_knowledge_source_id IS NULL AND resolved_knowledge_source_version_id IS NULL AND
          resolved_by_membership_id IS NULL AND resolved_at IS NULL AND
          dismissed_by_membership_id IS NULL AND dismissed_at IS NULL AND dismissal_reason IS NULL) OR
        (status = 'assigned' AND assigned_to_membership_id IS NOT NULL AND assigned_by_membership_id IS NOT NULL AND
          assigned_at IS NOT NULL AND
          resolved_knowledge_source_id IS NULL AND resolved_knowledge_source_version_id IS NULL AND
          resolved_by_membership_id IS NULL AND resolved_at IS NULL AND
          dismissed_by_membership_id IS NULL AND dismissed_at IS NULL AND dismissal_reason IS NULL) OR
        (status = 'resolved' AND assigned_to_membership_id IS NOT NULL AND assigned_by_membership_id IS NOT NULL AND
          assigned_at IS NOT NULL AND resolved_knowledge_source_id IS NOT NULL AND
          resolved_knowledge_source_version_id IS NOT NULL AND resolved_by_membership_id IS NOT NULL AND
          resolved_at IS NOT NULL AND dismissed_by_membership_id IS NULL AND dismissed_at IS NULL AND
          dismissal_reason IS NULL) OR
        (status = 'dismissed' AND dismissed_by_membership_id IS NOT NULL AND dismissed_at IS NOT NULL AND
          dismissal_reason IS NOT NULL AND resolved_knowledge_source_id IS NULL AND
          resolved_knowledge_source_version_id IS NULL AND resolved_by_membership_id IS NULL AND resolved_at IS NULL)
      SQL
      add_check_constraint :knowledge_improvement_candidates, state_constraint,
        name: "knowledge_improvement_candidates_state"
    end

    def protect_records
      execute <<~SQL
        CREATE FUNCTION protect_knowledge_improvement_candidate()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'TRUNCATE' THEN
            RAISE EXCEPTION 'knowledge improvement candidates cannot be truncated';
          END IF;
          IF TG_OP = 'DELETE' THEN
            IF NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            RAISE EXCEPTION 'knowledge improvement candidates cannot be deleted';
          END IF;
          IF ROW(
            NEW.workspace_id, NEW.source_crew_artifact_id, NEW.support_case_id, NEW.knowledge_source_id,
            NEW.reason_code, NEW.title, NEW.detail, NEW.created_by_membership_id, NEW.opened_at, NEW.created_at
          ) IS DISTINCT FROM ROW(
            OLD.workspace_id, OLD.source_crew_artifact_id, OLD.support_case_id, OLD.knowledge_source_id,
            OLD.reason_code, OLD.title, OLD.detail, OLD.created_by_membership_id, OLD.opened_at, OLD.created_at
          ) THEN
            RAISE EXCEPTION 'knowledge improvement candidate provenance is immutable';
          END IF;
          IF OLD.status = NEW.status THEN
            IF OLD.status = 'assigned' AND (
              NEW.assigned_to_membership_id IS DISTINCT FROM OLD.assigned_to_membership_id OR
              NEW.assigned_by_membership_id IS DISTINCT FROM OLD.assigned_by_membership_id OR
              NEW.assigned_at IS DISTINCT FROM OLD.assigned_at
            ) THEN
              RETURN NEW;
            END IF;
            IF NEW IS DISTINCT FROM OLD THEN
              RAISE EXCEPTION 'knowledge improvement candidate is immutable in its current state';
            END IF;
            RETURN NEW;
          END IF;
          IF OLD.status = 'open' AND NEW.status = 'triaged' THEN
            IF NEW.triaged_by_membership_id IS NULL OR NEW.triaged_at IS NULL OR NEW.triage_note IS NULL THEN
              RAISE EXCEPTION 'invalid knowledge improvement triage';
            END IF;
          ELSIF OLD.status IN ('open', 'triaged') AND NEW.status = 'assigned' THEN
            IF NEW.assigned_to_membership_id IS NULL OR NEW.assigned_by_membership_id IS NULL OR NEW.assigned_at IS NULL THEN
              RAISE EXCEPTION 'invalid knowledge improvement assignment';
            END IF;
          ELSIF OLD.status = 'assigned' AND NEW.status = 'resolved' THEN
            IF NEW.resolved_knowledge_source_id IS NULL OR NEW.resolved_knowledge_source_version_id IS NULL OR
                NEW.resolved_by_membership_id IS NULL OR NEW.resolved_at IS NULL THEN
              RAISE EXCEPTION 'invalid knowledge improvement resolution';
            END IF;
          ELSIF OLD.status IN ('open', 'triaged', 'assigned') AND NEW.status = 'dismissed' THEN
            IF NEW.dismissed_by_membership_id IS NULL OR NEW.dismissed_at IS NULL OR NEW.dismissal_reason IS NULL THEN
              RAISE EXCEPTION 'invalid knowledge improvement dismissal';
            END IF;
          ELSE
            RAISE EXCEPTION 'invalid knowledge improvement candidate transition';
          END IF;
          RETURN NEW;
        END;
        $$;
        CREATE TRIGGER knowledge_improvement_candidates_protect
          BEFORE UPDATE OR DELETE ON knowledge_improvement_candidates
          FOR EACH ROW EXECUTE FUNCTION protect_knowledge_improvement_candidate();
        CREATE TRIGGER knowledge_improvement_candidates_no_truncate
          BEFORE TRUNCATE ON knowledge_improvement_candidates
          FOR EACH STATEMENT EXECUTE FUNCTION protect_knowledge_improvement_candidate();
      SQL
    end

    def extend_content_expiry
      execute <<~SQL
        ALTER FUNCTION expire_workspace_content(bigint, timestamp without time zone)
          RENAME TO expire_workspace_content_before_knowledge_improvements;

        CREATE FUNCTION expire_workspace_content(target_workspace_id bigint, cutoff timestamp without time zone)
        RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
        SET search_path = public, pg_temp AS $$
        DECLARE
          affected integer;
          total integer;
        BEGIN
          total := expire_workspace_content_before_knowledge_improvements(target_workspace_id, cutoff);
          LOCK TABLE knowledge_improvement_candidates IN ACCESS EXCLUSIVE MODE;
          ALTER TABLE knowledge_improvement_candidates DISABLE TRIGGER USER;

          UPDATE knowledge_improvement_candidates
          SET detail = '[Expired by retention policy]',
              triage_note = CASE WHEN triage_note IS NULL THEN NULL ELSE '[Expired by retention policy]' END,
              dismissal_reason = CASE WHEN dismissal_reason IS NULL THEN NULL ELSE '[Expired by retention policy]' END,
              updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND opened_at < cutoff AND
            detail <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          ALTER TABLE knowledge_improvement_candidates ENABLE TRIGGER USER;
          RETURN total;
        END;
        $$;
        REVOKE ALL ON FUNCTION expire_workspace_content(bigint, timestamp without time zone) FROM PUBLIC;
      SQL
    end

    def restore_content_expiry
      execute <<~SQL
        DROP FUNCTION expire_workspace_content(bigint, timestamp without time zone);
        ALTER FUNCTION expire_workspace_content_before_knowledge_improvements(bigint, timestamp without time zone)
          RENAME TO expire_workspace_content;
      SQL
    end
end
