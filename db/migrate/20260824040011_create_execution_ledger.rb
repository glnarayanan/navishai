class CreateExecutionLedger < ActiveRecord::Migration[8.1]
  def change
    create_table :execution_runs do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :crew_task_id, null: false
      t.bigint :agent_profile_id, null: false
      t.bigint :agent_profile_version_id, null: false
      t.uuid :run_key, null: false, default: -> { "gen_random_uuid()" }
      t.string :request_key, null: false
      t.integer :attempt_number, null: false
      t.string :runtime_profile_key, null: false
      t.string :status, null: false, default: "admitting"
      t.integer :current_sequence, null: false, default: 0
      t.bigint :current_event_id
      t.integer :admission_attempt_count, null: false, default: 0
      t.datetime :admission_attempted_at
      t.string :last_admission_error
      t.bigint :input_units, null: false, default: 0
      t.bigint :output_units, null: false, default: 0
      t.text :output
      t.string :failure_code
      t.boolean :retryable
      t.datetime :admitted_at
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :execution_runs, :run_key, unique: true
    add_index :execution_runs, [ :workspace_id, :id ], unique: true
    add_index :execution_runs, [ :workspace_id, :request_key ], unique: true
    add_index :execution_runs, [ :crew_task_id, :attempt_number ], unique: true
    add_foreign_key :execution_runs, :crew_tasks,
      column: [ :workspace_id, :crew_task_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :execution_runs, :agent_profiles,
      column: [ :workspace_id, :agent_profile_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :execution_runs, :agent_profile_versions,
      column: [ :workspace_id, :agent_profile_id, :agent_profile_version_id ],
      primary_key: [ :workspace_id, :agent_profile_id, :id ]
    add_check_constraint :execution_runs,
      "status IN ('admitting', 'admitted', 'running', 'completed', 'failed', 'timed_out', 'canceled', 'policy_denied')",
      name: "execution_runs_status"
    add_check_constraint :execution_runs,
      "octet_length(request_key) BETWEEN 1 AND 128 AND attempt_number > 0 AND current_sequence >= 0 AND " \
      "admission_attempt_count >= 0 AND input_units >= 0 AND output_units >= 0",
      name: "execution_runs_bounds"
    add_check_constraint :execution_runs,
      "last_admission_error IS NULL OR octet_length(last_admission_error) BETWEEN 1 AND 100",
      name: "execution_runs_admission_error"
    add_check_constraint :execution_runs,
      "failure_code IS NULL OR octet_length(failure_code) BETWEEN 1 AND 100",
      name: "execution_runs_failure_code"
    add_check_constraint :execution_runs,
      "output IS NULL OR octet_length(output) <= 102400",
      name: "execution_runs_output"

    create_table :execution_events do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :execution_run_id, null: false
      t.uuid :event_key, null: false
      t.integer :sequence_number, null: false
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :data, null: false, default: {}
      t.string :payload_digest, null: false
      t.timestamps
    end
    add_index :execution_events, :event_key, unique: true
    add_index :execution_events, [ :execution_run_id, :sequence_number ], unique: true
    add_index :execution_events, [ :workspace_id, :execution_run_id, :id ], unique: true,
      name: "index_execution_events_on_workspace_run_id"
    add_foreign_key :execution_events, :execution_runs,
      column: [ :workspace_id, :execution_run_id ], primary_key: [ :workspace_id, :id ]
    add_check_constraint :execution_events, "sequence_number > 0", name: "execution_events_sequence"
    add_check_constraint :execution_events,
      "event_type IN ('run.admitted', 'run.started', 'tool.completed', 'output.produced', 'usage.observed', " \
      "'run.completed', 'run.failed', 'run.timed_out', 'run.canceled', 'run.policy_denied')",
      name: "execution_events_type"
    add_check_constraint :execution_events,
      "octet_length(data::text) <= 131072 AND payload_digest ~ '^[0-9a-f]{64}$'",
      name: "execution_events_payload"

    add_foreign_key :execution_runs, :execution_events,
      column: [ :workspace_id, :id, :current_event_id ],
      primary_key: [ :workspace_id, :execution_run_id, :id ], name: "fk_execution_runs_current_event"

    protect_execution_ledger
  end

  private
    def protect_execution_ledger
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION protect_execution_event()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
                RETURN OLD;
              END IF;
              RAISE EXCEPTION 'execution events are append only';
            END;
            $$;
            CREATE TRIGGER execution_events_append_only
            BEFORE UPDATE OR DELETE ON execution_events
            FOR EACH ROW EXECUTE FUNCTION protect_execution_event();
            CREATE TRIGGER execution_events_no_truncate
            BEFORE TRUNCATE ON execution_events
            FOR EACH STATEMENT EXECUTE FUNCTION protect_execution_event();

            CREATE FUNCTION require_linked_execution_event()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM execution_runs
                WHERE id = NEW.execution_run_id AND workspace_id = NEW.workspace_id
                  AND current_event_id = NEW.id AND current_sequence = NEW.sequence_number
              ) THEN
                RAISE EXCEPTION 'execution event must advance its run';
              END IF;
              RETURN NULL;
            END;
            $$;
            CREATE CONSTRAINT TRIGGER execution_events_require_link
            AFTER INSERT ON execution_events DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION require_linked_execution_event();

            CREATE FUNCTION protect_execution_run()
            RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE event_row execution_events%ROWTYPE;
            BEGIN
              IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
                RETURN OLD;
              END IF;
              IF TG_OP <> 'UPDATE' OR
                 ROW(OLD.id, OLD.workspace_id, OLD.crew_task_id, OLD.agent_profile_id,
                     OLD.agent_profile_version_id, OLD.run_key, OLD.request_key, OLD.attempt_number,
                     OLD.runtime_profile_key, OLD.created_at)
                   IS DISTINCT FROM
                 ROW(NEW.id, NEW.workspace_id, NEW.crew_task_id, NEW.agent_profile_id,
                     NEW.agent_profile_version_id, NEW.run_key, NEW.request_key, NEW.attempt_number,
                     NEW.runtime_profile_key, NEW.created_at) THEN
                RAISE EXCEPTION 'execution run identity is durable';
              END IF;

              IF NEW.current_sequence = OLD.current_sequence AND NEW.current_event_id IS NOT DISTINCT FROM OLD.current_event_id THEN
                IF OLD.status <> 'admitting' OR NEW.status <> OLD.status OR
                   ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
                       OLD.admitted_at, OLD.started_at, OLD.finished_at)
                     IS DISTINCT FROM
                   ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
                       NEW.admitted_at, NEW.started_at, NEW.finished_at) OR
                   NEW.admission_attempt_count < OLD.admission_attempt_count OR
                   NEW.admission_attempt_count > OLD.admission_attempt_count + 1 THEN
                  RAISE EXCEPTION 'execution admission update is invalid';
                END IF;
                RETURN NEW;
              END IF;

              IF NEW.current_sequence <> OLD.current_sequence + 1 OR NEW.current_event_id IS NULL THEN
                RAISE EXCEPTION 'execution run events must be ordered';
              END IF;
              SELECT * INTO event_row FROM execution_events WHERE id = NEW.current_event_id FOR UPDATE;
              IF event_row.id IS NULL OR event_row.workspace_id <> NEW.workspace_id OR
                 event_row.execution_run_id <> NEW.id OR event_row.sequence_number <> NEW.current_sequence THEN
                RAISE EXCEPTION 'execution run event does not match';
              END IF;
              IF NEW.admission_attempt_count <> OLD.admission_attempt_count OR
                 NEW.admission_attempted_at IS DISTINCT FROM OLD.admission_attempted_at OR
                 (event_row.event_type <> 'run.admitted' AND NEW.last_admission_error IS DISTINCT FROM OLD.last_admission_error) OR
                 (event_row.event_type = 'run.admitted' AND NEW.last_admission_error IS NOT NULL) OR
                 (OLD.current_event_id IS NOT NULL AND event_row.occurred_at <
                   (SELECT occurred_at FROM execution_events WHERE id = OLD.current_event_id)) THEN
                RAISE EXCEPTION 'execution event changed admission history or time order';
              END IF;
              IF (CASE event_row.event_type
                WHEN 'run.admitted' THEN OLD.status = 'admitting' AND NEW.status = 'admitted'
                  AND NEW.admitted_at = event_row.occurred_at AND OLD.admitted_at IS NULL
                  AND event_row.data->>'workspace_key' = (SELECT runner_key::text FROM workspaces WHERE id = NEW.workspace_id)
                  AND event_row.data->>'task_key' = (SELECT task_key::text FROM crew_tasks WHERE id = NEW.crew_task_id)
                  AND (event_row.data->>'attempt')::integer = NEW.attempt_number
                  AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
                          NEW.started_at, NEW.finished_at)
                    IS NOT DISTINCT FROM
                      ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
                          OLD.started_at, OLD.finished_at)
                WHEN 'run.started' THEN OLD.status = 'admitted' AND NEW.status = 'running'
                  AND NEW.started_at = event_row.occurred_at AND OLD.started_at IS NULL
                  AND octet_length(event_row.data->>'adapter') BETWEEN 1 AND 64
                  AND octet_length(event_row.data->>'scenario') BETWEEN 1 AND 100
                  AND (event_row.data->>'attempt')::integer = NEW.attempt_number
                  AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
                          NEW.admitted_at, NEW.finished_at)
                    IS NOT DISTINCT FROM
                      ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
                          OLD.admitted_at, OLD.finished_at)
                WHEN 'tool.completed' THEN OLD.status = 'running' AND NEW.status = OLD.status
                  AND octet_length(event_row.data->>'tool') BETWEEN 1 AND 64
                  AND octet_length(event_row.data->>'result') BETWEEN 1 AND 100
                  AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
                          NEW.admitted_at, NEW.started_at, NEW.finished_at)
                    IS NOT DISTINCT FROM
                      ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
                          OLD.admitted_at, OLD.started_at, OLD.finished_at)
                WHEN 'output.produced' THEN OLD.status = 'running' AND NEW.status = OLD.status
                  AND NEW.output = event_row.data->>'text'
                  AND ROW(NEW.input_units, NEW.output_units, NEW.failure_code, NEW.retryable,
                          NEW.admitted_at, NEW.started_at, NEW.finished_at)
                    IS NOT DISTINCT FROM
                      ROW(OLD.input_units, OLD.output_units, OLD.failure_code, OLD.retryable,
                          OLD.admitted_at, OLD.started_at, OLD.finished_at)
                WHEN 'usage.observed' THEN OLD.status = 'running' AND NEW.status = OLD.status
                  AND NEW.input_units = OLD.input_units + (event_row.data->>'input_units')::bigint
                  AND NEW.output_units = OLD.output_units + (event_row.data->>'output_units')::bigint
                  AND ROW(NEW.output, NEW.failure_code, NEW.retryable, NEW.admitted_at, NEW.started_at, NEW.finished_at)
                    IS NOT DISTINCT FROM
                      ROW(OLD.output, OLD.failure_code, OLD.retryable, OLD.admitted_at, OLD.started_at, OLD.finished_at)
                WHEN 'run.completed' THEN OLD.status = 'running' AND NEW.status = 'completed'
                  AND NEW.finished_at = event_row.occurred_at AND event_row.data->>'outcome' = 'completed'
                  AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
                          NEW.admitted_at, NEW.started_at)
                    IS NOT DISTINCT FROM
                      ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
                          OLD.admitted_at, OLD.started_at)
                WHEN 'run.failed' THEN OLD.status = 'running' AND NEW.status = 'failed'
                  AND NEW.failure_code = event_row.data->>'code'
                  AND NEW.retryable = (event_row.data->>'retryable')::boolean AND NEW.finished_at = event_row.occurred_at
                  AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
                    IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
                WHEN 'run.timed_out' THEN OLD.status = 'running' AND NEW.status = 'timed_out'
                  AND NEW.failure_code = 'timed_out' AND NEW.retryable = false AND NEW.finished_at = event_row.occurred_at
                  AND octet_length(event_row.data->>'reason') BETWEEN 1 AND 500
                  AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
                    IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
                WHEN 'run.canceled' THEN OLD.status = 'running' AND NEW.status = 'canceled'
                  AND NEW.failure_code = 'canceled' AND NEW.retryable = false AND NEW.finished_at = event_row.occurred_at
                  AND octet_length(event_row.data->>'reason') BETWEEN 1 AND 500
                  AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
                    IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
                WHEN 'run.policy_denied' THEN OLD.status = 'running' AND NEW.status = 'policy_denied'
                  AND NEW.failure_code = event_row.data->>'code' AND NEW.retryable = false AND NEW.finished_at = event_row.occurred_at
                  AND octet_length(event_row.data->>'code') BETWEEN 1 AND 100
                  AND octet_length(event_row.data->>'tool') BETWEEN 1 AND 64
                  AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
                    IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
                ELSE false
              END) IS NOT TRUE THEN
                RAISE EXCEPTION 'invalid execution run transition';
              END IF;
              RETURN NEW;
            END;
            $$;
            CREATE TRIGGER execution_runs_protect_record
            BEFORE UPDATE OR DELETE ON execution_runs
            FOR EACH ROW EXECUTE FUNCTION protect_execution_run();
            CREATE TRIGGER execution_runs_no_truncate
            BEFORE TRUNCATE ON execution_runs
            FOR EACH STATEMENT EXECUTE FUNCTION protect_execution_run();
          SQL
        end
        direction.down do
          execute "DROP FUNCTION IF EXISTS protect_execution_run() CASCADE"
          execute "DROP FUNCTION IF EXISTS require_linked_execution_event() CASCADE"
          execute "DROP FUNCTION IF EXISTS protect_execution_event() CASCADE"
        end
      end
    end
end
