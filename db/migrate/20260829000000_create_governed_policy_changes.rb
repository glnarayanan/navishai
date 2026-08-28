class CreateGovernedPolicyChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :governed_policy_proposals do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :resolution_contract_family_id, null: false
      t.bigint :agent_profile_id, null: false
      t.bigint :prior_resolution_contract_version_id, null: false
      t.bigint :resolution_contract_version_id, null: false
      t.bigint :prior_agent_profile_version_id, null: false
      t.bigint :agent_profile_version_id, null: false
      t.string :scope_kind, null: false
      t.string :reason, null: false
      t.bigint :created_by_membership_id, null: false
      t.bigint :created_by_user_id, null: false
      t.datetime :expired_at
      t.timestamps
    end
    add_index :governed_policy_proposals, [ :workspace_id, :id ], unique: true
    add_index :governed_policy_proposals, :resolution_contract_version_id, unique: true,
      name: "index_policy_proposals_candidate_contract"
    add_index :governed_policy_proposals, :agent_profile_version_id, unique: true,
      name: "index_policy_proposals_candidate_profile"

    create_table :governed_policy_subjects do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :governed_policy_proposal_id, null: false
      t.string :subject_kind, null: false
      t.bigint :support_case_id
      t.bigint :account_id
      t.bigint :agent_profile_id
      t.timestamps
    end
    add_index :governed_policy_subjects, [ :workspace_id, :id ], unique: true
    add_index :governed_policy_subjects, [ :governed_policy_proposal_id, :support_case_id ],
      unique: true, where: "subject_kind = 'support_case'", name: "index_policy_subjects_unique_case"
    add_index :governed_policy_subjects, [ :governed_policy_proposal_id, :account_id ],
      unique: true, where: "subject_kind = 'account'", name: "index_policy_subjects_unique_account"
    add_index :governed_policy_subjects, [ :governed_policy_proposal_id, :agent_profile_id ],
      unique: true, where: "subject_kind = 'agent_profile'", name: "index_policy_subjects_unique_profile"

    create_table :governed_policy_previews do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :governed_policy_proposal_id, null: false
      t.string :evidence_digest, null: false
      t.string :results_digest, null: false
      t.jsonb :source_snapshot, null: false, default: {}
      t.jsonb :results, null: false, default: []
      t.integer :subject_count, null: false
      t.bigint :created_by_membership_id, null: false
      t.bigint :created_by_user_id, null: false
      t.datetime :previewed_at, null: false
      t.datetime :expired_at
      t.timestamps
    end
    add_index :governed_policy_previews, [ :workspace_id, :id ], unique: true
    add_index :governed_policy_previews, [ :governed_policy_proposal_id, :evidence_digest, :results_digest ],
      unique: true, name: "index_governed_policy_previews_stable"
    add_index :governed_policy_previews, [ :workspace_id, :governed_policy_proposal_id, :id ],
      unique: true, name: "index_policy_previews_proposal_identity"

    create_table :governed_policy_publications do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :governed_policy_proposal_id, null: false
      t.bigint :governed_policy_preview_id
      t.bigint :supersedes_publication_id
      t.string :action, null: false
      t.bigint :resolution_contract_version_id, null: false
      t.bigint :agent_profile_version_id, null: false
      t.string :reason, null: false
      t.bigint :created_by_membership_id, null: false
      t.bigint :created_by_user_id, null: false
      t.datetime :published_at, null: false
      t.datetime :expired_at
      t.timestamps
    end
    add_index :governed_policy_publications, [ :workspace_id, :id ], unique: true
    add_index :governed_policy_publications, :governed_policy_preview_id, unique: true,
      where: "action = 'canary'", name: "index_policy_publications_one_canary_per_preview"
    add_index :governed_policy_publications, :supersedes_publication_id, unique: true,
      where: "supersedes_publication_id IS NOT NULL", name: "index_policy_publications_one_successor"
    add_index :governed_policy_publications,
      [ :workspace_id, :id, :resolution_contract_version_id, :agent_profile_version_id ],
      unique: true, name: "index_policy_publications_frozen_tuple"
    add_index :governed_policy_publications,
      [ :workspace_id, :id, :resolution_contract_version_id ],
      unique: true, name: "index_policy_publications_contract_tuple"

    add_reference :crew_tasks, :governed_policy_publication, index: true
    add_reference :crew_tasks, :resolution_contract_version, index: true
    add_reference :execution_runs, :governed_policy_publication, index: true
    add_reference :execution_runs, :resolution_contract_version, index: true
    add_reference :crew_artifacts, :governed_policy_publication, index: true
    add_reference :crew_task_events, :from_governed_policy_publication, index: false
    add_reference :crew_task_events, :to_governed_policy_publication, index: false
    add_reference :crew_task_events, :from_resolution_contract_version, index: false
    add_reference :crew_task_events, :to_resolution_contract_version, index: false
    add_index :crew_tasks,
      [ :workspace_id, :id, :governed_policy_publication_id, :resolution_contract_version_id,
        :assigned_agent_profile_version_id ],
      unique: true, name: "index_crew_tasks_frozen_policy_tuple"
    add_index :execution_runs,
      [ :workspace_id, :id, :crew_task_id, :governed_policy_publication_id,
        :resolution_contract_version_id ],
      unique: true, name: "index_execution_runs_frozen_policy_tuple"

    add_governed_foreign_keys
    add_governed_checks

    reversible do |direction|
      direction.up do
        protect_governed_records
        enforce_governed_integrity
        extend_content_expiry
      end
      direction.down do
        restore_content_expiry
        drop_governed_integrity
        drop_governed_protection
      end
    end
  end

  private
    def add_governed_foreign_keys
      add_foreign_key :governed_policy_proposals, :resolution_contract_families,
        column: [ :workspace_id, :resolution_contract_family_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_proposals_family"
      {
        prior_resolution_contract_version_id: "fk_policy_proposals_prior_contract",
        resolution_contract_version_id: "fk_policy_proposals_candidate_contract"
      }.each do |column, name|
        add_foreign_key :governed_policy_proposals, :resolution_contract_versions,
          column: [ :workspace_id, column ], primary_key: [ :workspace_id, :id ], name: name
      end
      add_foreign_key :governed_policy_proposals, :agent_profiles,
        column: [ :workspace_id, :agent_profile_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_proposals_profile"
      {
        prior_agent_profile_version_id: "fk_policy_proposals_prior_profile",
        agent_profile_version_id: "fk_policy_proposals_candidate_profile"
      }.each do |column, name|
        add_foreign_key :governed_policy_proposals, :agent_profile_versions,
          column: [ :workspace_id, :agent_profile_id, column ],
          primary_key: [ :workspace_id, :agent_profile_id, :id ], name: name
      end
      add_actor_foreign_key(:governed_policy_proposals, "created_by", "fk_policy_proposals_actor")

      add_foreign_key :governed_policy_subjects, :governed_policy_proposals,
        column: [ :workspace_id, :governed_policy_proposal_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_subjects_proposal"
      add_foreign_key :governed_policy_subjects, :support_cases,
        column: [ :workspace_id, :support_case_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_subjects_case"
      add_foreign_key :governed_policy_subjects, :accounts,
        column: [ :workspace_id, :account_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_subjects_account"
      add_foreign_key :governed_policy_subjects, :agent_profiles,
        column: [ :workspace_id, :agent_profile_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_subjects_profile"

      add_foreign_key :governed_policy_previews, :governed_policy_proposals,
        column: [ :workspace_id, :governed_policy_proposal_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_previews_proposal"
      add_actor_foreign_key(:governed_policy_previews, "created_by", "fk_policy_previews_actor")

      add_foreign_key :governed_policy_publications, :governed_policy_proposals,
        column: [ :workspace_id, :governed_policy_proposal_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_publications_proposal"
      add_foreign_key :governed_policy_publications, :governed_policy_previews,
        column: [ :workspace_id, :governed_policy_proposal_id, :governed_policy_preview_id ],
        primary_key: [ :workspace_id, :governed_policy_proposal_id, :id ],
        name: "fk_policy_publications_preview"
      add_foreign_key :governed_policy_publications, :governed_policy_publications,
        column: [ :workspace_id, :supersedes_publication_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_publications_supersedes"
      add_foreign_key :governed_policy_publications, :resolution_contract_versions,
        column: [ :workspace_id, :resolution_contract_version_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_publications_contract"
      add_foreign_key :governed_policy_publications, :agent_profile_versions,
        column: [ :workspace_id, :agent_profile_version_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_policy_publications_profile"
      add_actor_foreign_key(:governed_policy_publications, "created_by", "fk_policy_publications_actor")

      add_frozen_foreign_keys(:crew_tasks)
      add_frozen_foreign_keys(:execution_runs)
      add_foreign_key :crew_tasks, :governed_policy_publications,
        column: [ :workspace_id, :governed_policy_publication_id, :resolution_contract_version_id,
          :assigned_agent_profile_version_id ],
        primary_key: [ :workspace_id, :id, :resolution_contract_version_id, :agent_profile_version_id ],
        name: "fk_crew_tasks_exact_governed_policy"
      add_foreign_key :execution_runs, :crew_tasks,
        column: [ :workspace_id, :crew_task_id, :governed_policy_publication_id,
          :resolution_contract_version_id, :agent_profile_version_id ],
        primary_key: [ :workspace_id, :id, :governed_policy_publication_id,
          :resolution_contract_version_id, :assigned_agent_profile_version_id ],
        name: "fk_execution_runs_exact_task_policy"
      add_foreign_key :execution_runs, :governed_policy_publications,
        column: [ :workspace_id, :governed_policy_publication_id, :resolution_contract_version_id,
          :agent_profile_version_id ],
        primary_key: [ :workspace_id, :id, :resolution_contract_version_id, :agent_profile_version_id ],
        name: "fk_execution_runs_exact_governed_policy"
      add_foreign_key :crew_artifacts, :governed_policy_publications,
        column: [ :workspace_id, :governed_policy_publication_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_crew_artifacts_policy_publication"
      add_foreign_key :crew_artifacts, :governed_policy_publications,
        column: [ :workspace_id, :governed_policy_publication_id, :resolution_contract_version_id ],
        primary_key: [ :workspace_id, :id, :resolution_contract_version_id ],
        name: "fk_crew_artifacts_exact_governed_policy"
      add_foreign_key :crew_artifacts, :execution_runs,
        column: [ :workspace_id, :execution_run_id, :crew_task_id,
          :governed_policy_publication_id, :resolution_contract_version_id ],
        primary_key: [ :workspace_id, :id, :crew_task_id,
          :governed_policy_publication_id, :resolution_contract_version_id ],
        name: "fk_crew_artifacts_exact_run_policy"
      %i[from to].each do |direction|
        add_foreign_key :crew_task_events, :governed_policy_publications,
          column: [ :workspace_id, "#{direction}_governed_policy_publication_id" ],
          primary_key: [ :workspace_id, :id ], name: "fk_task_events_#{direction}_policy"
        add_foreign_key :crew_task_events, :resolution_contract_versions,
          column: [ :workspace_id, "#{direction}_resolution_contract_version_id" ],
          primary_key: [ :workspace_id, :id ], name: "fk_task_events_#{direction}_contract"
        add_foreign_key :crew_task_events, :governed_policy_publications,
          column: [ :workspace_id, "#{direction}_governed_policy_publication_id",
            "#{direction}_resolution_contract_version_id", "#{direction}_agent_profile_version_id" ],
          primary_key: [ :workspace_id, :id, :resolution_contract_version_id, :agent_profile_version_id ],
          name: "fk_task_events_#{direction}_exact_policy"
      end
    end

    def add_actor_foreign_key(table, prefix, name)
      add_foreign_key(table, :memberships,
        column: [ :workspace_id, "#{prefix}_membership_id", "#{prefix}_user_id" ],
        primary_key: [ :workspace_id, :id, :user_id ], name: name)
      add_foreign_key(table, :users, column: "#{prefix}_user_id")
    end

    def add_frozen_foreign_keys(table)
      add_foreign_key table, :governed_policy_publications,
        column: [ :workspace_id, :governed_policy_publication_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_#{table}_policy_publication"
      add_foreign_key table, :resolution_contract_versions,
        column: [ :workspace_id, :resolution_contract_version_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_#{table}_policy_contract"
    end

    def add_governed_checks
      add_check_constraint :governed_policy_proposals,
        "scope_kind IN ('support_case', 'account', 'agent_profile')", name: "policy_proposals_scope"
      add_check_constraint :governed_policy_proposals,
        "octet_length(btrim(reason)) BETWEEN 1 AND 500", name: "policy_proposals_reason"
      add_check_constraint :governed_policy_subjects,
        "(subject_kind = 'support_case' AND support_case_id IS NOT NULL AND account_id IS NULL AND agent_profile_id IS NULL) OR " \
        "(subject_kind = 'account' AND support_case_id IS NULL AND account_id IS NOT NULL AND agent_profile_id IS NULL) OR " \
        "(subject_kind = 'agent_profile' AND support_case_id IS NULL AND account_id IS NULL AND agent_profile_id IS NOT NULL)",
        name: "policy_subjects_shape"
      add_check_constraint :governed_policy_previews,
        "evidence_digest ~ '^[0-9a-f]{64}$' AND results_digest ~ '^[0-9a-f]{64}$' AND " \
        "jsonb_typeof(source_snapshot) = 'object' AND jsonb_typeof(results) = 'array' AND " \
        "subject_count BETWEEN 1 AND 50 AND jsonb_array_length(results) = subject_count AND " \
        "octet_length(source_snapshot::text) <= 524288 AND octet_length(results::text) <= 524288",
        name: "policy_previews_bounded"
      add_check_constraint :governed_policy_publications,
        "action IN ('canary', 'rollback') AND octet_length(btrim(reason)) BETWEEN 1 AND 500 AND " \
        "((action = 'canary' AND governed_policy_preview_id IS NOT NULL) OR " \
        "(action = 'rollback' AND governed_policy_preview_id IS NULL AND supersedes_publication_id IS NOT NULL))",
        name: "policy_publications_shape"
      add_check_constraint :crew_tasks,
        "governed_policy_publication_id IS NULL OR resolution_contract_version_id IS NOT NULL",
        name: "crew_tasks_governed_policy_shape"
      add_check_constraint :execution_runs,
        "governed_policy_publication_id IS NULL OR resolution_contract_version_id IS NOT NULL",
        name: "execution_runs_governed_policy_shape"
      add_check_constraint :crew_task_events,
        "from_governed_policy_publication_id IS NULL OR " \
        "(from_resolution_contract_version_id IS NOT NULL AND from_agent_profile_version_id IS NOT NULL)",
        name: "crew_task_events_from_governed_policy_shape"
      add_check_constraint :crew_task_events,
        "to_governed_policy_publication_id IS NULL OR " \
        "(to_resolution_contract_version_id IS NOT NULL AND to_agent_profile_version_id IS NOT NULL)",
        name: "crew_task_events_to_governed_policy_shape"
      add_check_constraint :crew_artifacts,
        "governed_policy_publication_id IS NULL OR resolution_contract_version_id IS NOT NULL",
        name: "crew_artifacts_governed_policy_shape"
    end

    def enforce_governed_integrity
      execute <<~SQL
        CREATE FUNCTION validate_governed_policy_subject_count(target_proposal_id bigint)
        RETURNS void LANGUAGE plpgsql AS $$
        DECLARE proposal_kind text; subject_total integer;
        BEGIN
          SELECT scope_kind INTO proposal_kind FROM governed_policy_proposals WHERE id = target_proposal_id;
          IF proposal_kind IS NULL THEN RETURN; END IF;
          SELECT count(*) INTO subject_total FROM governed_policy_subjects
            WHERE governed_policy_proposal_id = target_proposal_id AND subject_kind = proposal_kind;
          IF subject_total NOT BETWEEN 1 AND 50 OR
              (proposal_kind = 'agent_profile' AND subject_total <> 1) OR
              EXISTS (SELECT 1 FROM governed_policy_subjects
                WHERE governed_policy_proposal_id = target_proposal_id AND subject_kind <> proposal_kind) THEN
            RAISE EXCEPTION 'governed policy subject scope must contain 1..50 matching records and one profile';
          END IF;
        END;
        $$;

        CREATE FUNCTION check_governed_policy_subject_count() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          PERFORM validate_governed_policy_subject_count(COALESCE(NEW.governed_policy_proposal_id, OLD.governed_policy_proposal_id));
          RETURN COALESCE(NEW, OLD);
        END;
        $$;
        CREATE CONSTRAINT TRIGGER governed_policy_subjects_count
          AFTER INSERT OR UPDATE OR DELETE ON governed_policy_subjects
          DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_governed_policy_subject_count();

        CREATE FUNCTION check_governed_policy_proposal_subject_count() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          PERFORM validate_governed_policy_subject_count(NEW.id);
          RETURN NEW;
        END;
        $$;
        CREATE CONSTRAINT TRIGGER governed_policy_proposals_subject_count
          AFTER INSERT ON governed_policy_proposals
          DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_governed_policy_proposal_subject_count();

        CREATE FUNCTION validate_governed_policy_publication() RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE policy governed_policy_proposals%ROWTYPE; prior governed_policy_publications%ROWTYPE;
        BEGIN
          SELECT * INTO policy FROM governed_policy_proposals
            WHERE id = NEW.governed_policy_proposal_id AND workspace_id = NEW.workspace_id;
          IF NEW.supersedes_publication_id IS NOT NULL THEN
            SELECT * INTO prior FROM governed_policy_publications
              WHERE id = NEW.supersedes_publication_id AND workspace_id = NEW.workspace_id;
            IF prior.id IS NULL OR NOT EXISTS (
                SELECT 1 FROM governed_policy_proposals predecessor
                WHERE predecessor.id = prior.governed_policy_proposal_id
                  AND predecessor.workspace_id = NEW.workspace_id
                  AND predecessor.scope_kind = policy.scope_kind
                  AND predecessor.resolution_contract_family_id = policy.resolution_contract_family_id
                  AND predecessor.agent_profile_id = policy.agent_profile_id
              ) OR EXISTS (
                (SELECT subject_kind, support_case_id, account_id, agent_profile_id
                  FROM governed_policy_subjects WHERE governed_policy_proposal_id = policy.id
                 EXCEPT
                 SELECT subject_kind, support_case_id, account_id, agent_profile_id
                  FROM governed_policy_subjects WHERE governed_policy_proposal_id = prior.governed_policy_proposal_id)
                UNION ALL
                (SELECT subject_kind, support_case_id, account_id, agent_profile_id
                  FROM governed_policy_subjects WHERE governed_policy_proposal_id = prior.governed_policy_proposal_id
                 EXCEPT
                 SELECT subject_kind, support_case_id, account_id, agent_profile_id
                  FROM governed_policy_subjects WHERE governed_policy_proposal_id = policy.id)
              ) THEN
              RAISE EXCEPTION 'superseded publication does not match exact canary scope';
            END IF;
          END IF;
          IF NEW.action = 'canary' THEN
            IF NEW.resolution_contract_version_id <> policy.resolution_contract_version_id OR
                NEW.agent_profile_version_id <> policy.agent_profile_version_id OR
                NOT EXISTS (SELECT 1 FROM governed_policy_previews WHERE id = NEW.governed_policy_preview_id
                  AND governed_policy_proposal_id = policy.id AND workspace_id = NEW.workspace_id) THEN
              RAISE EXCEPTION 'canary publication does not match proposal evidence';
            END IF;
          ELSE
            IF NEW.resolution_contract_version_id <> policy.prior_resolution_contract_version_id OR
                NEW.agent_profile_version_id <> policy.prior_agent_profile_version_id OR
                prior.governed_policy_proposal_id <> policy.id THEN
              RAISE EXCEPTION 'rollback publication does not match proposal history';
            END IF;
          END IF;
          RETURN NEW;
        END;
        $$;
        CREATE TRIGGER governed_policy_publications_integrity BEFORE INSERT ON governed_policy_publications
          FOR EACH ROW EXECUTE FUNCTION validate_governed_policy_publication();

        CREATE FUNCTION validate_governed_crew_task_projection() RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE event_row crew_task_events%ROWTYPE;
        BEGIN
          IF TG_OP <> 'UPDATE' OR NEW.current_event_id IS NOT DISTINCT FROM OLD.current_event_id THEN
            RETURN NEW;
          END IF;
          SELECT * INTO event_row FROM crew_task_events WHERE id = NEW.current_event_id;
          IF event_row.from_governed_policy_publication_id IS DISTINCT FROM
               (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.governed_policy_publication_id END) OR
             event_row.to_governed_policy_publication_id IS DISTINCT FROM NEW.governed_policy_publication_id OR
             event_row.from_resolution_contract_version_id IS DISTINCT FROM
               (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.resolution_contract_version_id END) OR
             event_row.to_resolution_contract_version_id IS DISTINCT FROM NEW.resolution_contract_version_id THEN
            RAISE EXCEPTION 'crew task governed policy projection must match its event';
          END IF;
          RETURN NEW;
        END;
        $$;
        CREATE TRIGGER crew_tasks_governed_policy_projection BEFORE UPDATE ON crew_tasks
          FOR EACH ROW EXECUTE FUNCTION validate_governed_crew_task_projection();
      SQL
    end

    def drop_governed_integrity
      execute "DROP FUNCTION IF EXISTS validate_governed_policy_publication() CASCADE"
      execute "DROP FUNCTION IF EXISTS validate_governed_crew_task_projection() CASCADE"
      execute "DROP FUNCTION IF EXISTS check_governed_policy_proposal_subject_count() CASCADE"
      execute "DROP FUNCTION IF EXISTS check_governed_policy_subject_count() CASCADE"
      execute "DROP FUNCTION IF EXISTS validate_governed_policy_subject_count(bigint) CASCADE"
    end

    def protect_governed_records
      %w[proposal subject preview publication].each do |kind|
        table = "governed_policy_#{kind.pluralize}"
        execute <<~SQL
          CREATE FUNCTION protect_governed_policy_#{kind}() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            RAISE EXCEPTION 'governed policy #{kind.pluralize} are append only';
          END;
          $$;
          CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
            FOR EACH ROW EXECUTE FUNCTION protect_governed_policy_#{kind}();
          CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table}
            FOR EACH STATEMENT EXECUTE FUNCTION protect_governed_policy_#{kind}();
        SQL
      end
    end

    def drop_governed_protection
      %w[proposal subject preview publication].each do |kind|
        execute "DROP FUNCTION IF EXISTS protect_governed_policy_#{kind}() CASCADE"
      end
    end

    def extend_content_expiry
      execute <<~SQL
        ALTER FUNCTION expire_workspace_content(bigint, timestamp without time zone)
          RENAME TO expire_workspace_content_before_governed_policy;
        CREATE FUNCTION expire_workspace_content(target_workspace_id bigint, cutoff timestamp without time zone)
        RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
        DECLARE affected integer; total integer;
        BEGIN
          total := expire_workspace_content_before_governed_policy(target_workspace_id, cutoff);
          LOCK TABLE governed_policy_proposals, governed_policy_previews, governed_policy_publications
            IN ACCESS EXCLUSIVE MODE;
          ALTER TABLE governed_policy_proposals DISABLE TRIGGER USER;
          ALTER TABLE governed_policy_previews DISABLE TRIGGER USER;
          ALTER TABLE governed_policy_publications DISABLE TRIGGER USER;

          UPDATE governed_policy_proposals
            SET reason = '[Expired by retention policy]', expired_at = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP
            WHERE workspace_id = target_workspace_id AND created_at < cutoff AND expired_at IS NULL;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE governed_policy_previews
            SET source_snapshot = '{"retention":"expired"}'::jsonb,
                results = COALESCE((
                  SELECT jsonb_agg(jsonb_build_object(
                    'subject_kind', item->>'subject_kind', 'subject_id', item->'subject_id',
                    'old_decision', '{"retention":"expired"}'::jsonb,
                    'proposed_decision', '{"retention":"expired"}'::jsonb,
                    'changes', '[]'::jsonb, 'facts', '[]'::jsonb, 'result', 'expired'
                  ) ORDER BY ordinal)
                  FROM jsonb_array_elements(results) WITH ORDINALITY AS values(item, ordinal)
                ), '[]'::jsonb),
                expired_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
            WHERE workspace_id = target_workspace_id AND previewed_at < cutoff AND expired_at IS NULL;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE governed_policy_publications
            SET reason = '[Expired by retention policy]', expired_at = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP
            WHERE workspace_id = target_workspace_id AND published_at < cutoff AND expired_at IS NULL;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          ALTER TABLE governed_policy_publications ENABLE TRIGGER USER;
          ALTER TABLE governed_policy_previews ENABLE TRIGGER USER;
          ALTER TABLE governed_policy_proposals ENABLE TRIGGER USER;
          RETURN total;
        END;
        $$;
        REVOKE ALL ON FUNCTION expire_workspace_content(bigint, timestamp without time zone) FROM PUBLIC;
      SQL
    end

    def restore_content_expiry
      execute <<~SQL
        DROP FUNCTION expire_workspace_content(bigint, timestamp without time zone);
        ALTER FUNCTION expire_workspace_content_before_governed_policy(bigint, timestamp without time zone)
          RENAME TO expire_workspace_content;
      SQL
    end
end
