class AddWorkspaceSearchSelection < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :web_search_provider_key, :string
    add_column :public_web_searches, :requested_provider_key, :string
    add_check_constraint :workspaces, "web_search_provider_key ~ '^[a-z][a-z0-9_]{0,63}$'", name: "workspace_search_provider_key"
    add_check_constraint :public_web_searches, "requested_provider_key ~ '^[a-z][a-z0-9_]{0,63}$'", name: "search_requested_provider_key"
    add_check_constraint :public_web_searches, "requested_provider_key IS NULL OR provider_key IS NULL OR requested_provider_key = provider_key", name: "search_provider_matches_request"
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_search_provider_selection() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF NEW.requested_provider_key IS DISTINCT FROM OLD.requested_provider_key THEN
              RAISE EXCEPTION 'search provider selection is immutable';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER search_provider_selection_immutable BEFORE UPDATE ON public_web_searches
          FOR EACH ROW EXECUTE FUNCTION protect_search_provider_selection();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER search_provider_selection_immutable ON public_web_searches"
        execute "DROP FUNCTION protect_search_provider_selection()"
      end
    end
  end
end
