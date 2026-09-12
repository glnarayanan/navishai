class AddHealthScorecardCrewProposals < ActiveRecord::Migration[8.1]
  def up
    add_column :crew_tasks, :health_scorecard_id, :bigint
    add_index :crew_tasks, [ :workspace_id, :health_scorecard_id, :status ],
      name: "index_crew_tasks_on_scorecard_and_status"
    add_foreign_key :crew_tasks, :health_scorecards,
      column: [ :workspace_id, :health_scorecard_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_crew_tasks_health_scorecard"
    remove_check_constraint :crew_tasks, name: "crew_tasks_scope"
    add_check_constraint :crew_tasks, <<~SQL.squish, name: "crew_tasks_scope"
      (scope_kind = 'support_case' AND support_case_id IS NOT NULL AND account_id IS NULL AND health_scorecard_id IS NULL) OR
      (scope_kind = 'account' AND account_id IS NOT NULL AND support_case_id IS NULL AND health_scorecard_id IS NULL) OR
      (scope_kind = 'health_scorecard' AND health_scorecard_id IS NOT NULL AND support_case_id IS NULL AND account_id IS NULL)
    SQL

    create_table :health_scorecard_proposals do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :health_scorecard_id, null: false
      t.bigint :crew_task_id, null: false
      t.bigint :execution_run_id, null: false
      t.bigint :created_by_membership_id, null: false
      t.bigint :created_by_user_id, null: false
      t.text :prompt, null: false
      t.jsonb :proposed_definition
      t.text :explanation, null: false
      t.jsonb :assumptions, null: false, default: []
      t.jsonb :unsupported_requests, null: false, default: []
      t.jsonb :missing_evidence, null: false, default: []
      t.string :validation_status, null: false
      t.text :validation_detail
      t.string :payload_digest, null: false
      t.timestamps
    end
    add_index :health_scorecard_proposals, [ :workspace_id, :id ], unique: true
    add_index :health_scorecard_proposals, :execution_run_id, unique: true
    add_index :health_scorecard_proposals, [ :health_scorecard_id, :created_at ],
      name: "index_health_scorecard_proposals_on_scorecard_and_created"
    add_foreign_key :health_scorecard_proposals, :health_scorecards,
      column: [ :workspace_id, :health_scorecard_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :health_scorecard_proposals, :crew_tasks,
      column: [ :workspace_id, :crew_task_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :health_scorecard_proposals, :execution_runs,
      column: [ :workspace_id, :execution_run_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :health_scorecard_proposals, :memberships,
      column: [ :workspace_id, :created_by_membership_id, :created_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_health_scorecard_proposals_actor"
    add_foreign_key :health_scorecard_proposals, :users, column: :created_by_user_id
    add_check_constraint :health_scorecard_proposals,
      "octet_length(prompt) BETWEEN 1 AND 2000 AND octet_length(explanation) BETWEEN 1 AND 8000 AND " \
      "(validation_detail IS NULL OR octet_length(validation_detail) BETWEEN 1 AND 2000)",
      name: "health_scorecard_proposals_content"
    add_check_constraint :health_scorecard_proposals,
      "validation_status IN ('valid', 'invalid', 'unsupported', 'incomplete')",
      name: "health_scorecard_proposals_status"
    add_check_constraint :health_scorecard_proposals,
      "payload_digest ~ '^[0-9a-f]{64}$'", name: "health_scorecard_proposals_digest"
    add_check_constraint :health_scorecard_proposals,
      "jsonb_typeof(assumptions) = 'array' AND jsonb_array_length(assumptions) <= 20 AND " \
      "jsonb_typeof(unsupported_requests) = 'array' AND jsonb_array_length(unsupported_requests) <= 20 AND " \
      "jsonb_typeof(missing_evidence) = 'array' AND jsonb_array_length(missing_evidence) <= 20",
      name: "health_scorecard_proposals_collections"
    add_check_constraint :health_scorecard_proposals,
      "(validation_status = 'valid' AND proposed_definition IS NOT NULL) OR " \
      "(validation_status <> 'valid' AND proposed_definition IS NULL)",
      name: "health_scorecard_proposals_definition"

    add_column :health_scorecard_versions, :source_proposal_id, :bigint
    add_index :health_scorecard_versions, :source_proposal_id, unique: true,
      where: "source_proposal_id IS NOT NULL"
    add_foreign_key :health_scorecard_versions, :health_scorecard_proposals,
      column: [ :workspace_id, :source_proposal_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_health_scorecard_versions_source_proposal"

    replace_crew_guards
    protect_proposals
    expire_proposals
  end

  def down
    restore_expiry
    restore_crew_guards
    execute "DROP TRIGGER IF EXISTS health_scorecard_proposals_append_only ON health_scorecard_proposals"
    execute "DROP TRIGGER IF EXISTS health_scorecard_proposals_no_truncate ON health_scorecard_proposals"
    remove_foreign_key :health_scorecard_versions, name: "fk_health_scorecard_versions_source_proposal"
    remove_index :health_scorecard_versions, :source_proposal_id
    remove_column :health_scorecard_versions, :source_proposal_id
    drop_table :health_scorecard_proposals
    remove_check_constraint :crew_tasks, name: "crew_tasks_scope"
    add_check_constraint :crew_tasks,
      "(scope_kind = 'support_case' AND support_case_id IS NOT NULL AND account_id IS NULL) OR " \
      "(scope_kind = 'account' AND account_id IS NOT NULL AND support_case_id IS NULL)",
      name: "crew_tasks_scope"
    remove_foreign_key :crew_tasks, name: "fk_crew_tasks_health_scorecard"
    remove_index :crew_tasks, name: "index_crew_tasks_on_scorecard_and_status"
    remove_column :crew_tasks, :health_scorecard_id
  end

  private
    def replace_crew_guards
      execute <<~SQL
        CREATE OR REPLACE FUNCTION protect_crew_task()
        RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE old_sequence integer; event_row crew_task_events%ROWTYPE;
        BEGIN
          IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
            RETURN OLD;
          END IF;
          IF TG_OP <> 'UPDATE' OR
             ROW(OLD.id, OLD.workspace_id, OLD.task_key, OLD.scope_kind, OLD.support_case_id, OLD.account_id,
                 OLD.health_scorecard_id, OLD.crew_template_id, OLD.owner_membership_id, OLD.owner_user_id, OLD.title,
                 OLD.input_context, OLD.expected_output, OLD.created_at)
               IS DISTINCT FROM
             ROW(NEW.id, NEW.workspace_id, NEW.task_key, NEW.scope_kind, NEW.support_case_id, NEW.account_id,
                 NEW.health_scorecard_id, NEW.crew_template_id, NEW.owner_membership_id, NEW.owner_user_id, NEW.title,
                 NEW.input_context, NEW.expected_output, NEW.created_at) OR
             NEW.current_event_id IS NOT DISTINCT FROM OLD.current_event_id THEN
            RAISE EXCEPTION 'crew task identity and history are durable';
          END IF;
          SELECT * INTO event_row FROM crew_task_events WHERE id = NEW.current_event_id FOR UPDATE;
          SELECT sequence_number INTO old_sequence FROM crew_task_events WHERE id = OLD.current_event_id;
          IF event_row.id IS NULL OR event_row.workspace_id <> NEW.workspace_id OR event_row.crew_task_id <> NEW.id OR
             event_row.sequence_number <> COALESCE(old_sequence, 0) + 1 OR
             event_row.from_status IS DISTINCT FROM
               (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.status END) OR
             event_row.to_status IS DISTINCT FROM NEW.status OR
             event_row.from_agent_profile_id IS DISTINCT FROM
               (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.assigned_agent_profile_id END) OR
             event_row.to_agent_profile_id IS DISTINCT FROM NEW.assigned_agent_profile_id THEN
            RAISE EXCEPTION 'crew task update must advance its matching event';
          END IF;
          IF event_row.from_agent_profile_version_id IS DISTINCT FROM
               (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.assigned_agent_profile_version_id END) OR
             event_row.to_agent_profile_version_id IS DISTINCT FROM NEW.assigned_agent_profile_version_id OR
             NOT (CASE event_row.event_kind
               WHEN 'created' THEN OLD.current_event_id IS NULL AND event_row.from_status IS NULL
                 AND event_row.body IS NULL AND event_row.evidence_kind IS NULL
                 AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'status_changed' THEN OLD.status <> NEW.status AND OLD.assigned_agent_profile_id = NEW.assigned_agent_profile_id
                 AND event_row.evidence_kind IS NULL AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'handoff' THEN OLD.status = NEW.status AND OLD.assigned_agent_profile_id <> NEW.assigned_agent_profile_id
                 AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NULL
                 AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'comment' THEN OLD.status = NEW.status AND OLD.assigned_agent_profile_id = NEW.assigned_agent_profile_id
                 AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NULL
                 AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'evidence_added' THEN OLD.status = NEW.status AND OLD.assigned_agent_profile_id = NEW.assigned_agent_profile_id
                 AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NOT NULL AND event_row.evidence_locator IS NOT NULL
                 AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'review_requested' THEN OLD.status <> NEW.status AND NEW.status = 'review_requested'
                 AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NULL
                 AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'review_resolved' THEN OLD.status = 'review_requested' AND NEW.status = 'in_progress'
                 AND event_row.review_outcome = 'changes_requested' AND event_row.body IS NOT NULL
                 AND event_row.evidence_kind IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'outcome_recorded' THEN NEW.status IN ('completed', 'failed', 'canceled')
                 AND event_row.outcome_kind = NEW.status AND event_row.body IS NOT NULL
                 AND event_row.evidence_kind IS NULL AND (
                   (NEW.status = 'completed' AND OLD.status = 'review_requested' AND event_row.review_outcome = 'approved') OR
                   (NEW.status IN ('failed', 'canceled') AND event_row.review_outcome IS NULL)
                 )
               ELSE false
             END) THEN
            RAISE EXCEPTION 'crew task event does not match its recorded change';
          END IF;
          IF OLD.current_event_id IS NOT NULL AND OLD.status <> NEW.status AND NOT (
            (OLD.status = 'pending' AND NEW.status IN ('ready', 'blocked', 'canceled')) OR
            (OLD.status = 'ready' AND NEW.status IN ('in_progress', 'blocked', 'canceled')) OR
            (OLD.status = 'in_progress' AND NEW.status IN ('blocked', 'review_requested', 'completed', 'failed', 'canceled')) OR
            (OLD.status = 'blocked' AND NEW.status IN ('ready', 'in_progress', 'failed', 'canceled')) OR
            (OLD.status = 'review_requested' AND NEW.status IN ('in_progress', 'completed', 'failed')) OR
            (OLD.status = 'failed' AND NEW.status IN ('ready', 'canceled'))
          ) THEN
            RAISE EXCEPTION 'invalid crew task transition';
          END IF;
          IF NEW.status IN ('ready', 'in_progress', 'review_requested', 'completed') AND EXISTS (
            SELECT 1 FROM crew_task_dependencies dependency
            JOIN crew_tasks prerequisite ON prerequisite.id = dependency.depends_on_task_id
            WHERE dependency.crew_task_id = NEW.id AND prerequisite.status <> 'completed'
          ) THEN
            RAISE EXCEPTION 'crew task dependencies are incomplete';
          END IF;
          RETURN NEW;
        END;
        $$;

        CREATE OR REPLACE FUNCTION validate_crew_task_dependency()
        RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE task_scope record; dependency_scope record;
        BEGIN
          SELECT scope_kind, support_case_id, account_id, health_scorecard_id INTO task_scope
          FROM crew_tasks WHERE id = NEW.crew_task_id AND workspace_id = NEW.workspace_id FOR UPDATE;
          SELECT scope_kind, support_case_id, account_id, health_scorecard_id INTO dependency_scope
          FROM crew_tasks WHERE id = NEW.depends_on_task_id AND workspace_id = NEW.workspace_id FOR UPDATE;
          IF task_scope IS NULL OR dependency_scope IS NULL OR
             ROW(task_scope.scope_kind, task_scope.support_case_id, task_scope.account_id, task_scope.health_scorecard_id)
               IS DISTINCT FROM
             ROW(dependency_scope.scope_kind, dependency_scope.support_case_id, dependency_scope.account_id,
                 dependency_scope.health_scorecard_id) OR
             EXISTS (
               WITH RECURSIVE ancestors(id) AS (
                 SELECT depends_on_task_id FROM crew_task_dependencies
                 WHERE crew_task_id = NEW.depends_on_task_id
                 UNION
                 SELECT dependency.depends_on_task_id
                 FROM crew_task_dependencies dependency JOIN ancestors ON dependency.crew_task_id = ancestors.id
               ) SELECT 1 FROM ancestors WHERE id = NEW.crew_task_id
             ) OR EXISTS (
               SELECT 1 FROM crew_tasks task
               JOIN crew_tasks prerequisite ON prerequisite.id = NEW.depends_on_task_id
               WHERE task.id = NEW.crew_task_id AND task.status <> 'pending' AND prerequisite.status <> 'completed'
             ) THEN
            RAISE EXCEPTION 'crew task dependency must share scope and cannot form a cycle';
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end

    def restore_crew_guards
      execute <<~SQL
        CREATE OR REPLACE FUNCTION protect_crew_task()
        RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE old_sequence integer; event_row crew_task_events%ROWTYPE;
        BEGIN
          IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
            RETURN OLD;
          END IF;
          IF TG_OP <> 'UPDATE' OR
             ROW(OLD.id, OLD.workspace_id, OLD.task_key, OLD.scope_kind, OLD.support_case_id, OLD.account_id,
                 OLD.crew_template_id, OLD.owner_membership_id, OLD.owner_user_id, OLD.title,
                 OLD.input_context, OLD.expected_output, OLD.created_at)
               IS DISTINCT FROM
             ROW(NEW.id, NEW.workspace_id, NEW.task_key, NEW.scope_kind, NEW.support_case_id, NEW.account_id,
                 NEW.crew_template_id, NEW.owner_membership_id, NEW.owner_user_id, NEW.title,
                 NEW.input_context, NEW.expected_output, NEW.created_at) OR
             NEW.current_event_id IS NOT DISTINCT FROM OLD.current_event_id THEN
            RAISE EXCEPTION 'crew task identity and history are durable';
          END IF;
          SELECT * INTO event_row FROM crew_task_events WHERE id = NEW.current_event_id FOR UPDATE;
          SELECT sequence_number INTO old_sequence FROM crew_task_events WHERE id = OLD.current_event_id;
          IF event_row.id IS NULL OR event_row.workspace_id <> NEW.workspace_id OR event_row.crew_task_id <> NEW.id OR
             event_row.sequence_number <> COALESCE(old_sequence, 0) + 1 OR
             event_row.from_status IS DISTINCT FROM
               (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.status END) OR
             event_row.to_status IS DISTINCT FROM NEW.status OR
             event_row.from_agent_profile_id IS DISTINCT FROM
               (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.assigned_agent_profile_id END) OR
             event_row.to_agent_profile_id IS DISTINCT FROM NEW.assigned_agent_profile_id THEN
            RAISE EXCEPTION 'crew task update must advance its matching event';
          END IF;
          IF event_row.from_agent_profile_version_id IS DISTINCT FROM
               (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.assigned_agent_profile_version_id END) OR
             event_row.to_agent_profile_version_id IS DISTINCT FROM NEW.assigned_agent_profile_version_id OR
             NOT (CASE event_row.event_kind
               WHEN 'created' THEN OLD.current_event_id IS NULL AND event_row.from_status IS NULL
                 AND event_row.body IS NULL AND event_row.evidence_kind IS NULL
                 AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'status_changed' THEN OLD.status <> NEW.status AND OLD.assigned_agent_profile_id = NEW.assigned_agent_profile_id
                 AND event_row.evidence_kind IS NULL AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'handoff' THEN OLD.status = NEW.status AND OLD.assigned_agent_profile_id <> NEW.assigned_agent_profile_id
                 AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NULL
                 AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'comment' THEN OLD.status = NEW.status AND OLD.assigned_agent_profile_id = NEW.assigned_agent_profile_id
                 AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NULL
                 AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'evidence_added' THEN OLD.status = NEW.status AND OLD.assigned_agent_profile_id = NEW.assigned_agent_profile_id
                 AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NOT NULL AND event_row.evidence_locator IS NOT NULL
                 AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'review_requested' THEN OLD.status <> NEW.status AND NEW.status = 'review_requested'
                 AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NULL
                 AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'review_resolved' THEN OLD.status = 'review_requested' AND NEW.status = 'in_progress'
                 AND event_row.review_outcome = 'changes_requested' AND event_row.body IS NOT NULL
                 AND event_row.evidence_kind IS NULL AND event_row.outcome_kind IS NULL
               WHEN 'outcome_recorded' THEN NEW.status IN ('completed', 'failed', 'canceled')
                 AND event_row.outcome_kind = NEW.status AND event_row.body IS NOT NULL
                 AND event_row.evidence_kind IS NULL AND (
                   (NEW.status = 'completed' AND OLD.status = 'review_requested' AND event_row.review_outcome = 'approved') OR
                   (NEW.status IN ('failed', 'canceled') AND event_row.review_outcome IS NULL)
                 )
               ELSE false
             END) THEN
            RAISE EXCEPTION 'crew task event does not match its recorded change';
          END IF;
          IF OLD.current_event_id IS NOT NULL AND OLD.status <> NEW.status AND NOT (
            (OLD.status = 'pending' AND NEW.status IN ('ready', 'blocked', 'canceled')) OR
            (OLD.status = 'ready' AND NEW.status IN ('in_progress', 'blocked', 'canceled')) OR
            (OLD.status = 'in_progress' AND NEW.status IN ('blocked', 'review_requested', 'completed', 'failed', 'canceled')) OR
            (OLD.status = 'blocked' AND NEW.status IN ('ready', 'in_progress', 'failed', 'canceled')) OR
            (OLD.status = 'review_requested' AND NEW.status IN ('in_progress', 'completed', 'failed')) OR
            (OLD.status = 'failed' AND NEW.status IN ('ready', 'canceled'))
          ) THEN
            RAISE EXCEPTION 'invalid crew task transition';
          END IF;
          IF NEW.status IN ('ready', 'in_progress', 'review_requested', 'completed') AND EXISTS (
            SELECT 1 FROM crew_task_dependencies dependency
            JOIN crew_tasks prerequisite ON prerequisite.id = dependency.depends_on_task_id
            WHERE dependency.crew_task_id = NEW.id AND prerequisite.status <> 'completed'
          ) THEN
            RAISE EXCEPTION 'crew task dependencies are incomplete';
          END IF;
          RETURN NEW;
        END;
        $$;

        CREATE OR REPLACE FUNCTION validate_crew_task_dependency()
        RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE task_scope record; dependency_scope record;
        BEGIN
          SELECT scope_kind, support_case_id, account_id INTO task_scope
          FROM crew_tasks WHERE id = NEW.crew_task_id AND workspace_id = NEW.workspace_id FOR UPDATE;
          SELECT scope_kind, support_case_id, account_id INTO dependency_scope
          FROM crew_tasks WHERE id = NEW.depends_on_task_id AND workspace_id = NEW.workspace_id FOR UPDATE;
          IF task_scope IS NULL OR dependency_scope IS NULL OR
             ROW(task_scope.scope_kind, task_scope.support_case_id, task_scope.account_id)
               IS DISTINCT FROM
             ROW(dependency_scope.scope_kind, dependency_scope.support_case_id, dependency_scope.account_id) OR
             EXISTS (
               WITH RECURSIVE ancestors(id) AS (
                 SELECT depends_on_task_id FROM crew_task_dependencies
                 WHERE crew_task_id = NEW.depends_on_task_id
                 UNION
                 SELECT dependency.depends_on_task_id
                 FROM crew_task_dependencies dependency JOIN ancestors ON dependency.crew_task_id = ancestors.id
               ) SELECT 1 FROM ancestors WHERE id = NEW.crew_task_id
             ) OR EXISTS (
               SELECT 1 FROM crew_tasks task
               JOIN crew_tasks prerequisite ON prerequisite.id = NEW.depends_on_task_id
               WHERE task.id = NEW.crew_task_id AND task.status <> 'pending' AND prerequisite.status <> 'completed'
             ) THEN
            RAISE EXCEPTION 'crew task dependency must share scope and cannot form a cycle';
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end

    def expire_proposals
      execute <<~SQL
        CREATE OR REPLACE FUNCTION expire_workspace_content(target_workspace_id bigint, cutoff timestamp without time zone)
        RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
        DECLARE affected integer; total integer;
        BEGIN
          total := expire_workspace_content_before_governed_policy(target_workspace_id, cutoff);
          LOCK TABLE health_scorecard_proposals IN ACCESS EXCLUSIVE MODE;
          ALTER TABLE health_scorecard_proposals DISABLE TRIGGER USER;
          UPDATE health_scorecard_proposals
            SET prompt = '[Expired by retention policy]',
                explanation = '[Expired by retention policy]',
                assumptions = '[]'::jsonb,
                unsupported_requests = '[]'::jsonb,
                missing_evidence = '[]'::jsonb,
                validation_detail = CASE WHEN validation_detail IS NULL THEN NULL ELSE '[Expired by retention policy]' END,
                updated_at = CURRENT_TIMESTAMP
            WHERE workspace_id = target_workspace_id AND created_at < cutoff
              AND prompt <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;
          ALTER TABLE health_scorecard_proposals ENABLE TRIGGER USER;

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
      SQL
    end

    def restore_expiry
      execute <<~SQL
        CREATE OR REPLACE FUNCTION expire_workspace_content(target_workspace_id bigint, cutoff timestamp without time zone)
        RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
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
      SQL
    end

    def protect_proposals
      execute <<~SQL
        CREATE TRIGGER health_scorecard_proposals_append_only
          BEFORE UPDATE OR DELETE ON health_scorecard_proposals
          FOR EACH ROW EXECUTE FUNCTION protect_health_scorecard_record();
        CREATE TRIGGER health_scorecard_proposals_no_truncate
          BEFORE TRUNCATE ON health_scorecard_proposals
          FOR EACH STATEMENT EXECUTE FUNCTION protect_health_scorecard_record();
      SQL
    end
end
