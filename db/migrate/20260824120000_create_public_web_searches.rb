class CreatePublicWebSearches < ActiveRecord::Migration[8.1]
  def change
    create_table :public_web_searches do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :crew_task, null: false
      t.string :request_key, null: false
      t.text :query, null: false
      t.string :provider_key
      t.string :status, null: false, default: "searching"
      t.string :policy_decision, null: false, default: "allowed"
      t.bigint :cost_units, null: false, default: 0
      t.string :failure_code
      t.bigint :requested_by_membership_id, null: false
      t.bigint :requested_by_user_id, null: false
      t.datetime :retrieved_at
      t.timestamps
    end
    add_index :public_web_searches, [ :workspace_id, :id ], unique: true
    add_index :public_web_searches, [ :workspace_id, :request_key ], unique: true
    add_foreign_key :public_web_searches, :crew_tasks,
      column: [ :workspace_id, :crew_task_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_foreign_key :public_web_searches, :memberships,
      column: [ :workspace_id, :requested_by_membership_id, :requested_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :public_web_searches, :users, column: :requested_by_user_id
    add_check_constraint :public_web_searches,
      "octet_length(request_key) BETWEEN 1 AND 128 AND octet_length(query) BETWEEN 2 AND 500 AND " \
      "status IN ('searching', 'completed', 'failed') AND policy_decision IN ('allowed', 'redacted') AND cost_units >= 0",
      name: "public_web_searches_state"
    add_check_constraint :public_web_searches,
      "(status = 'searching' AND provider_key IS NULL AND failure_code IS NULL AND retrieved_at IS NULL) OR " \
      "(status = 'completed' AND provider_key ~ '^[a-z][a-z0-9_]{0,63}$' AND failure_code IS NULL AND retrieved_at IS NOT NULL) OR " \
      "(status = 'failed' AND provider_key IS NULL AND failure_code ~ '^[a-z][a-z0-9_]{0,99}$' AND retrieved_at IS NULL)",
      name: "public_web_searches_result"

    create_table :public_web_search_results do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :public_web_search, null: false
      t.integer :rank, null: false
      t.string :citation_key, null: false
      t.string :title, null: false
      t.text :url, null: false
      t.text :excerpt, null: false, default: ""
      t.datetime :published_at
      t.datetime :retrieved_at, null: false
      t.string :content_digest, null: false
      t.timestamps
    end
    add_index :public_web_search_results, [ :workspace_id, :id ], unique: true
    add_index :public_web_search_results, [ :public_web_search_id, :rank ], unique: true
    add_index :public_web_search_results, [ :public_web_search_id, :url ], unique: true
    add_index :public_web_search_results, :citation_key, unique: true
    add_foreign_key :public_web_search_results, :public_web_searches,
      column: [ :workspace_id, :public_web_search_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_check_constraint :public_web_search_results,
      "rank BETWEEN 1 AND 10 AND citation_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' AND " \
      "octet_length(title) BETWEEN 1 AND 500 AND octet_length(url) BETWEEN 9 AND 2048 AND " \
      "url ~ '^https://' AND octet_length(excerpt) <= 4000 AND content_digest ~ '^[0-9a-f]{64}$'",
      name: "public_web_search_results_content"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_public_web_search()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
              RAISE EXCEPTION 'public web search identity is immutable';
            ELSIF ROW(OLD.id, OLD.workspace_id, OLD.crew_task_id, OLD.request_key, OLD.query,
              OLD.requested_by_membership_id, OLD.requested_by_user_id, OLD.created_at)
              IS DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.crew_task_id, NEW.request_key, NEW.query,
              NEW.requested_by_membership_id, NEW.requested_by_user_id, NEW.created_at) THEN
              RAISE EXCEPTION 'public web search identity is immutable';
            END IF;
            IF OLD.status <> 'searching' OR NEW.status NOT IN ('completed', 'failed') THEN
              RAISE EXCEPTION 'public web search result is terminal';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER public_web_searches_protect
          BEFORE UPDATE OR DELETE ON public_web_searches
          FOR EACH ROW EXECUTE FUNCTION protect_public_web_search();
          CREATE TRIGGER public_web_searches_no_truncate
          BEFORE TRUNCATE ON public_web_searches
          FOR EACH STATEMENT EXECUTE FUNCTION protect_public_web_search();

          CREATE FUNCTION protect_public_web_search_result()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'INSERT' THEN
              PERFORM 1 FROM public_web_searches
              WHERE id = NEW.public_web_search_id AND workspace_id = NEW.workspace_id AND status = 'completed';
              IF NOT FOUND THEN
                RAISE EXCEPTION 'public web search results require a completed search';
              END IF;
              RETURN NEW;
            END IF;
            RAISE EXCEPTION 'public web search results are append-only';
          END;
          $$;
          CREATE TRIGGER public_web_search_results_no_update
          BEFORE INSERT OR UPDATE OR DELETE ON public_web_search_results
          FOR EACH ROW EXECUTE FUNCTION protect_public_web_search_result();
          CREATE TRIGGER public_web_search_results_no_truncate
          BEFORE TRUNCATE ON public_web_search_results
          FOR EACH STATEMENT EXECUTE FUNCTION protect_public_web_search_result();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER IF EXISTS public_web_search_results_no_truncate ON public_web_search_results"
        execute "DROP TRIGGER IF EXISTS public_web_search_results_no_update ON public_web_search_results"
        execute "DROP FUNCTION IF EXISTS protect_public_web_search_result()"
        execute "DROP TRIGGER IF EXISTS public_web_searches_no_truncate ON public_web_searches"
        execute "DROP TRIGGER IF EXISTS public_web_searches_protect ON public_web_searches"
        execute "DROP FUNCTION IF EXISTS protect_public_web_search()"
      end
    end
  end
end
