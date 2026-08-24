class CreateCrewWorkRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :crew_tasks do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.uuid :task_key, null: false, default: -> { "gen_random_uuid()" }
      t.string :scope_kind, null: false
      t.bigint :support_case_id
      t.bigint :account_id
      t.bigint :crew_template_id, null: false
      t.bigint :assigned_agent_profile_id, null: false
      t.bigint :assigned_agent_profile_version_id, null: false
      t.bigint :owner_membership_id, null: false
      t.bigint :owner_user_id, null: false
      t.string :title, null: false
      t.text :input_context, null: false
      t.text :expected_output, null: false
      t.string :status, null: false
      t.bigint :current_event_id
      t.timestamps
    end
    add_index :crew_tasks, :task_key, unique: true
    add_index :crew_tasks, [ :workspace_id, :id ], unique: true
    add_index :crew_tasks, [ :workspace_id, :support_case_id, :status ], name: "index_crew_tasks_on_case_and_status"
    add_index :crew_tasks, [ :workspace_id, :account_id, :status ], name: "index_crew_tasks_on_account_and_status"
    add_foreign_key :crew_tasks, :support_cases,
      column: [ :workspace_id, :support_case_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :crew_tasks, :accounts,
      column: [ :workspace_id, :account_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :crew_tasks, :crew_templates,
      column: [ :workspace_id, :crew_template_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :crew_tasks, :agent_profiles,
      column: [ :workspace_id, :crew_template_id, :assigned_agent_profile_id ],
      primary_key: [ :workspace_id, :crew_template_id, :id ], name: "fk_crew_tasks_assigned_profile"
    add_foreign_key :crew_tasks, :agent_profile_versions,
      column: [ :workspace_id, :assigned_agent_profile_id, :assigned_agent_profile_version_id ],
      primary_key: [ :workspace_id, :agent_profile_id, :id ], name: "fk_crew_tasks_assigned_version"
    add_foreign_key :crew_tasks, :memberships,
      column: [ :workspace_id, :owner_membership_id, :owner_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_crew_tasks_owner"
    add_foreign_key :crew_tasks, :users, column: :owner_user_id
    add_check_constraint :crew_tasks,
      "(scope_kind = 'support_case' AND support_case_id IS NOT NULL AND account_id IS NULL) OR " \
      "(scope_kind = 'account' AND account_id IS NOT NULL AND support_case_id IS NULL)",
      name: "crew_tasks_scope"
    add_check_constraint :crew_tasks,
      "status IN ('pending', 'ready', 'in_progress', 'blocked', 'review_requested', 'completed', 'failed', 'canceled')",
      name: "crew_tasks_status"
    add_check_constraint :crew_tasks,
      "octet_length(title) BETWEEN 1 AND 200 AND octet_length(input_context) BETWEEN 1 AND 8000 AND " \
      "octet_length(expected_output) BETWEEN 1 AND 8000",
      name: "crew_tasks_content"

    create_table :crew_task_dependencies do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :crew_task_id, null: false
      t.bigint :depends_on_task_id, null: false
      t.timestamps
    end
    add_index :crew_task_dependencies, [ :crew_task_id, :depends_on_task_id ], unique: true,
      name: "index_crew_task_dependencies_unique"
    add_foreign_key :crew_task_dependencies, :crew_tasks,
      column: [ :workspace_id, :crew_task_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :crew_task_dependencies, :crew_tasks,
      column: [ :workspace_id, :depends_on_task_id ], primary_key: [ :workspace_id, :id ]
    add_check_constraint :crew_task_dependencies,
      "crew_task_id <> depends_on_task_id", name: "crew_task_dependencies_not_self"

    create_table :crew_task_events do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :crew_task_id, null: false
      t.integer :sequence_number, null: false
      t.string :event_kind, null: false
      t.string :source, null: false
      t.bigint :actor_membership_id
      t.bigint :actor_user_id
      t.string :from_status
      t.string :to_status, null: false
      t.bigint :from_agent_profile_id
      t.bigint :to_agent_profile_id, null: false
      t.bigint :from_agent_profile_version_id
      t.bigint :to_agent_profile_version_id, null: false
      t.text :body
      t.string :evidence_kind
      t.string :evidence_locator
      t.string :review_outcome
      t.string :outcome_kind
      t.timestamps
    end
    add_index :crew_task_events, [ :workspace_id, :crew_task_id, :id ], unique: true,
      name: "index_crew_task_events_on_workspace_task_id"
    add_index :crew_task_events, [ :crew_task_id, :sequence_number ], unique: true
    add_foreign_key :crew_task_events, :crew_tasks,
      column: [ :workspace_id, :crew_task_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :crew_task_events, :agent_profiles,
      column: [ :workspace_id, :from_agent_profile_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :crew_task_events, :agent_profiles,
      column: [ :workspace_id, :to_agent_profile_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :crew_task_events, :agent_profile_versions,
      column: [ :workspace_id, :from_agent_profile_id, :from_agent_profile_version_id ],
      primary_key: [ :workspace_id, :agent_profile_id, :id ], name: "fk_crew_task_events_from_version"
    add_foreign_key :crew_task_events, :agent_profile_versions,
      column: [ :workspace_id, :to_agent_profile_id, :to_agent_profile_version_id ],
      primary_key: [ :workspace_id, :agent_profile_id, :id ], name: "fk_crew_task_events_to_version"
    add_foreign_key :crew_task_events, :memberships,
      column: [ :workspace_id, :actor_membership_id, :actor_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_crew_task_events_actor"
    add_foreign_key :crew_task_events, :users, column: :actor_user_id
    add_check_constraint :crew_task_events,
      "sequence_number > 0", name: "crew_task_events_sequence"
    add_check_constraint :crew_task_events,
      "event_kind IN ('created', 'status_changed', 'handoff', 'comment', 'evidence_added', " \
      "'review_requested', 'review_resolved', 'outcome_recorded')",
      name: "crew_task_events_kind"
    add_check_constraint :crew_task_events,
      "source IN ('web', 'task', 'runner', 'system')", name: "crew_task_events_source"
    add_check_constraint :crew_task_events,
      "(actor_membership_id IS NULL AND actor_user_id IS NULL) OR " \
      "(actor_membership_id IS NOT NULL AND actor_user_id IS NOT NULL)",
      name: "crew_task_events_actor"
    add_check_constraint :crew_task_events,
      "body IS NULL OR octet_length(body) BETWEEN 1 AND 20000", name: "crew_task_events_body"
    add_check_constraint :crew_task_events,
      "evidence_locator IS NULL OR octet_length(evidence_locator) BETWEEN 1 AND 2000",
      name: "crew_task_events_evidence_locator"
    add_check_constraint :crew_task_events,
      "evidence_kind IS NULL OR evidence_kind IN ('conversation', 'case', 'account', 'knowledge', 'public_web', 'other')",
      name: "crew_task_events_evidence_kind"
    add_check_constraint :crew_task_events,
      "review_outcome IS NULL OR review_outcome IN ('approved', 'changes_requested')",
      name: "crew_task_events_review_outcome"
    add_check_constraint :crew_task_events,
      "outcome_kind IS NULL OR outcome_kind IN ('completed', 'failed', 'canceled')",
      name: "crew_task_events_outcome_kind"

    add_foreign_key :crew_tasks, :crew_task_events,
      column: [ :workspace_id, :id, :current_event_id ],
      primary_key: [ :workspace_id, :crew_task_id, :id ], name: "fk_crew_tasks_current_event"

    protect_crew_work
  end

  private
    def protect_crew_work
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION protect_crew_task_event()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
                RETURN OLD;
              END IF;
              RAISE EXCEPTION 'crew task events are append only';
            END;
            $$;
            CREATE TRIGGER crew_task_events_append_only
            BEFORE UPDATE OR DELETE ON crew_task_events
            FOR EACH ROW EXECUTE FUNCTION protect_crew_task_event();
            CREATE TRIGGER crew_task_events_no_truncate
            BEFORE TRUNCATE ON crew_task_events
            FOR EACH STATEMENT EXECUTE FUNCTION protect_crew_task_event();

            CREATE FUNCTION require_linked_crew_task_event()
            RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE current_sequence integer;
            BEGIN
              SELECT event.sequence_number INTO current_sequence
              FROM crew_tasks task JOIN crew_task_events event ON event.id = task.current_event_id
              WHERE task.id = NEW.crew_task_id AND task.workspace_id = NEW.workspace_id;
              IF current_sequence IS NULL OR current_sequence < NEW.sequence_number THEN
                RAISE EXCEPTION 'crew task event must advance its task';
              END IF;
              RETURN NULL;
            END;
            $$;
            CREATE CONSTRAINT TRIGGER crew_task_events_require_link
            AFTER INSERT ON crew_task_events DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION require_linked_crew_task_event();

            CREATE FUNCTION protect_crew_task_dependency()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
                RETURN OLD;
              END IF;
              RAISE EXCEPTION 'crew task dependencies are append only';
            END;
            $$;
            CREATE TRIGGER crew_task_dependencies_append_only
            BEFORE UPDATE OR DELETE ON crew_task_dependencies
            FOR EACH ROW EXECUTE FUNCTION protect_crew_task_dependency();
            CREATE TRIGGER crew_task_dependencies_no_truncate
            BEFORE TRUNCATE ON crew_task_dependencies
            FOR EACH STATEMENT EXECUTE FUNCTION protect_crew_task_dependency();

            CREATE FUNCTION validate_crew_task_dependency()
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
            CREATE TRIGGER crew_task_dependencies_validate
            BEFORE INSERT ON crew_task_dependencies
            FOR EACH ROW EXECUTE FUNCTION validate_crew_task_dependency();

            CREATE FUNCTION require_current_crew_task_event()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM crew_tasks
                WHERE id = NEW.id AND workspace_id = NEW.workspace_id AND current_event_id IS NOT NULL
              ) THEN
                RAISE EXCEPTION 'crew task must have a current event';
              END IF;
              RETURN NULL;
            END;
            $$;
            CREATE CONSTRAINT TRIGGER crew_tasks_require_current_event
            AFTER INSERT OR UPDATE ON crew_tasks DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION require_current_crew_task_event();

            CREATE FUNCTION protect_crew_task()
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
            CREATE TRIGGER crew_tasks_protect_record
            BEFORE UPDATE OR DELETE ON crew_tasks
            FOR EACH ROW EXECUTE FUNCTION protect_crew_task();
            CREATE TRIGGER crew_tasks_no_truncate
            BEFORE TRUNCATE ON crew_tasks
            FOR EACH STATEMENT EXECUTE FUNCTION protect_crew_task();
          SQL
        end
        direction.down do
          execute "DROP FUNCTION IF EXISTS protect_crew_task() CASCADE"
          execute "DROP FUNCTION IF EXISTS require_current_crew_task_event() CASCADE"
          execute "DROP FUNCTION IF EXISTS require_linked_crew_task_event() CASCADE"
          execute "DROP FUNCTION IF EXISTS validate_crew_task_dependency() CASCADE"
          execute "DROP FUNCTION IF EXISTS protect_crew_task_dependency() CASCADE"
          execute "DROP FUNCTION IF EXISTS protect_crew_task_event() CASCADE"
        end
      end
    end
end
