class CreateCrewArtifacts < ActiveRecord::Migration[8.1]
  def change
    add_column :execution_runs, :input_context, :text
    add_column :execution_runs, :input_artifact_id, :bigint
    reversible do |direction|
      direction.up do
        execute <<~SQL
          UPDATE execution_runs run
          SET input_context = task.input_context
          FROM crew_tasks task
          WHERE task.id = run.crew_task_id
        SQL
        execute <<~SQL
          CREATE FUNCTION protect_execution_run_context()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF NEW.input_context IS DISTINCT FROM OLD.input_context OR
               NEW.input_artifact_id IS DISTINCT FROM OLD.input_artifact_id THEN
              RAISE EXCEPTION 'execution run context is immutable';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER execution_runs_immutable_context
          BEFORE UPDATE ON execution_runs
          FOR EACH ROW EXECUTE FUNCTION protect_execution_run_context();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER execution_runs_immutable_context ON execution_runs;
          DROP FUNCTION protect_execution_run_context();
        SQL
      end
    end
    change_column_null :execution_runs, :input_context, false
    add_check_constraint :execution_runs,
      "octet_length(input_context) BETWEEN 1 AND 131072", name: "execution_runs_input_context"

    create_table :crew_artifacts do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :crew_task_id, null: false
      t.bigint :execution_run_id, null: false
      t.bigint :supersedes_artifact_id
      t.bigint :target_artifact_id
      t.uuid :artifact_key, null: false, default: -> { "gen_random_uuid()" }
      t.integer :version_number, null: false
      t.string :artifact_kind, null: false
      t.text :body, null: false
      t.text :uncertainty, null: false
      t.string :review_outcome
      t.jsonb :citations, null: false, default: []
      t.jsonb :conflicts, null: false, default: []
      t.jsonb :change_requests, null: false, default: []
      t.string :payload_digest, null: false
      t.timestamps
    end
    add_index :crew_artifacts, :artifact_key, unique: true
    add_index :crew_artifacts, :execution_run_id, unique: true
    add_index :crew_artifacts, [ :workspace_id, :id ], unique: true
    add_index :execution_runs, :input_artifact_id
    add_index :crew_artifacts, [ :crew_task_id, :artifact_kind, :version_number ], unique: true,
      name: "index_crew_artifacts_on_task_kind_version"
    add_index :execution_runs, [ :workspace_id, :id, :crew_task_id ], unique: true,
      name: "index_execution_runs_on_workspace_id_task"
    add_foreign_key :crew_artifacts, :crew_tasks,
      column: [ :workspace_id, :crew_task_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :crew_artifacts, :execution_runs,
      column: [ :workspace_id, :execution_run_id, :crew_task_id ],
      primary_key: [ :workspace_id, :id, :crew_task_id ]
    add_foreign_key :crew_artifacts, :crew_artifacts,
      column: [ :workspace_id, :supersedes_artifact_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_crew_artifacts_supersedes"
    add_foreign_key :crew_artifacts, :crew_artifacts,
      column: [ :workspace_id, :target_artifact_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_crew_artifacts_target"
    add_foreign_key :execution_runs, :crew_artifacts,
      column: [ :workspace_id, :input_artifact_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_execution_runs_input_artifact"
    add_check_constraint :crew_artifacts, "version_number > 0", name: "crew_artifacts_version"
    add_check_constraint :crew_artifacts,
      "artifact_kind IN ('investigation', 'draft', 'quality_review')", name: "crew_artifacts_kind"
    add_check_constraint :crew_artifacts,
      "octet_length(body) BETWEEN 1 AND 51200 AND octet_length(uncertainty) BETWEEN 1 AND 4000",
      name: "crew_artifacts_content"
    add_check_constraint :crew_artifacts,
      "review_outcome IS NULL OR review_outcome IN ('approved', 'changes_requested')",
      name: "crew_artifacts_review_outcome"
    add_check_constraint :crew_artifacts,
      "(artifact_kind = 'quality_review' AND target_artifact_id IS NOT NULL AND review_outcome IS NOT NULL) OR " \
      "(artifact_kind <> 'quality_review' AND target_artifact_id IS NULL AND review_outcome IS NULL)",
      name: "crew_artifacts_review_shape"
    add_check_constraint :crew_artifacts,
      "jsonb_typeof(citations) = 'array' AND jsonb_array_length(citations) <= 20 AND " \
      "jsonb_typeof(conflicts) = 'array' AND jsonb_array_length(conflicts) <= 20 AND " \
      "jsonb_typeof(change_requests) = 'array' AND jsonb_array_length(change_requests) <= 20",
      name: "crew_artifacts_collections"
    add_check_constraint :crew_artifacts,
      "payload_digest ~ '^[0-9a-f]{64}$'", name: "crew_artifacts_digest"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_crew_artifact()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            RAISE EXCEPTION 'crew artifacts are append only';
          END;
          $$;
          CREATE TRIGGER crew_artifacts_append_only
          BEFORE UPDATE OR DELETE ON crew_artifacts
          FOR EACH ROW EXECUTE FUNCTION protect_crew_artifact();
          CREATE TRIGGER crew_artifacts_no_truncate
          BEFORE TRUNCATE ON crew_artifacts
          FOR EACH STATEMENT EXECUTE FUNCTION protect_crew_artifact();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER crew_artifacts_no_truncate ON crew_artifacts;
          DROP TRIGGER crew_artifacts_append_only ON crew_artifacts;
          DROP FUNCTION protect_crew_artifact();
        SQL
      end
    end
  end
end
