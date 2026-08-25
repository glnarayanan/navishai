class AddMemoryContextStatusToExecutionRuns < ActiveRecord::Migration[8.1]
  def up
    add_column :agent_profile_versions, :memory_required, :boolean, null: false, default: false
    add_column :execution_runs, :memory_context_status, :string, null: false, default: "not_applicable"
    add_column :execution_runs, :memory_context_detail, :string
    add_check_constraint :execution_runs,
      "memory_context_status IN ('not_applicable', 'available', 'degraded') AND " \
      "((memory_context_status = 'degraded' AND memory_context_detail IS NOT NULL) OR " \
      "(memory_context_status <> 'degraded' AND memory_context_detail IS NULL))",
      name: "execution_runs_memory_context"
    add_check_constraint :execution_runs,
      "memory_context_detail IS NULL OR octet_length(memory_context_detail) BETWEEN 1 AND 100",
      name: "execution_runs_memory_context_detail"

    execute <<~SQL
          CREATE FUNCTION protect_execution_run_memory_context()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF ROW(OLD.memory_context_status, OLD.memory_context_detail)
              IS DISTINCT FROM ROW(NEW.memory_context_status, NEW.memory_context_detail) THEN
              RAISE EXCEPTION 'execution run memory context is immutable';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER execution_runs_memory_context_immutable
          BEFORE UPDATE ON execution_runs
          FOR EACH ROW EXECUTE FUNCTION protect_execution_run_memory_context();
    SQL
  end

  def down
    execute "DROP TRIGGER execution_runs_memory_context_immutable ON execution_runs"
    execute "DROP FUNCTION protect_execution_run_memory_context()"
    remove_check_constraint :execution_runs, name: "execution_runs_memory_context_detail"
    remove_check_constraint :execution_runs, name: "execution_runs_memory_context"
    remove_column :execution_runs, :memory_context_detail
    remove_column :execution_runs, :memory_context_status
    remove_column :agent_profile_versions, :memory_required
  end
end
