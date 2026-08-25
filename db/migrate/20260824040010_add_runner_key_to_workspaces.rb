class AddRunnerKeyToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :runner_key, :uuid, null: false, default: -> { "gen_random_uuid()" }
    add_index :workspaces, :runner_key, unique: true

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_workspace_runner_key()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF OLD.runner_key IS DISTINCT FROM NEW.runner_key THEN
              RAISE EXCEPTION 'workspace runner key is durable';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER workspaces_protect_runner_key
          BEFORE UPDATE ON workspaces
          FOR EACH ROW EXECUTE FUNCTION protect_workspace_runner_key();
        SQL
      end
      direction.down do
        execute "DROP FUNCTION IF EXISTS protect_workspace_runner_key() CASCADE"
      end
    end
  end
end
