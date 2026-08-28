class CreateUsageCostRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :usage_rate_settings do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :current_version_id
      t.timestamps
    end
    add_index :usage_rate_settings, :workspace_id, unique: true
    add_index :usage_rate_settings, [ :workspace_id, :id ], unique: true

    create_table :usage_rate_versions do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :usage_rate_setting_id, null: false
      t.integer :version_number, null: false
      t.string :currency, null: false
      t.bigint :input_rate_micros_per_million
      t.bigint :output_rate_micros_per_million
      t.bigint :search_rate_micros_per_million
      t.string :source_name, null: false
      t.bigint :created_by_membership_id, null: false
      t.bigint :created_by_user_id, null: false
      t.datetime :published_at, null: false
      t.timestamps
    end
    add_index :usage_rate_versions, [ :workspace_id, :id ], unique: true
    add_index :usage_rate_versions, [ :usage_rate_setting_id, :version_number ], unique: true,
      name: "index_usage_rate_versions_on_setting_version"
    add_index :usage_rate_versions, [ :workspace_id, :usage_rate_setting_id, :id ], unique: true,
      name: "index_usage_rate_versions_tenant_chain"
    add_foreign_key :usage_rate_versions, :usage_rate_settings,
      column: [ :workspace_id, :usage_rate_setting_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_usage_rate_versions_setting"
    add_foreign_key :usage_rate_versions, :memberships,
      column: [ :workspace_id, :created_by_membership_id, :created_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_usage_rate_versions_actor"
    add_foreign_key :usage_rate_versions, :users, column: :created_by_user_id
    add_foreign_key :usage_rate_settings, :usage_rate_versions,
      column: [ :workspace_id, :id, :current_version_id ],
      primary_key: [ :workspace_id, :usage_rate_setting_id, :id ],
      name: "fk_usage_rate_settings_current_version"
    add_check_constraint :usage_rate_versions, "version_number > 0",
      name: "usage_rate_versions_number"
    add_check_constraint :usage_rate_versions,
      "currency ~ '^[A-Z]{3}$' AND octet_length(source_name) BETWEEN 1 AND 100",
      name: "usage_rate_versions_identity"
    add_check_constraint :usage_rate_versions,
      "(input_rate_micros_per_million IS NOT NULL OR output_rate_micros_per_million IS NOT NULL OR " \
      "search_rate_micros_per_million IS NOT NULL) AND " \
      "(input_rate_micros_per_million IS NULL OR input_rate_micros_per_million BETWEEN 0 AND 1000000000000) AND " \
      "(output_rate_micros_per_million IS NULL OR output_rate_micros_per_million BETWEEN 0 AND 1000000000000) AND " \
      "(search_rate_micros_per_million IS NULL OR search_rate_micros_per_million BETWEEN 0 AND 1000000000000)",
      name: "usage_rate_versions_rates"

    add_column :execution_runs, :usage_rate_version_id, :bigint
    add_column :public_web_searches, :usage_rate_version_id, :bigint
    add_index :execution_runs, :usage_rate_version_id
    add_index :public_web_searches, :usage_rate_version_id
    add_foreign_key :execution_runs, :usage_rate_versions,
      column: [ :workspace_id, :usage_rate_version_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_execution_runs_usage_rate"
    add_foreign_key :public_web_searches, :usage_rate_versions,
      column: [ :workspace_id, :usage_rate_version_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_public_web_searches_usage_rate"

    create_table :usage_cost_snapshots do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :execution_run_id
      t.bigint :public_web_search_id
      t.bigint :applied_usage_rate_version_id
      t.string :status, null: false
      t.string :source
      t.string :currency
      t.bigint :amount_micros
      t.bigint :observed_input_units
      t.bigint :observed_output_units
      t.bigint :observed_search_units
      t.jsonb :calculation_provenance, null: false, default: {}
      t.datetime :captured_at, null: false
      t.timestamps
    end
    add_index :usage_cost_snapshots, [ :workspace_id, :id ], unique: true
    add_index :usage_cost_snapshots, :execution_run_id, unique: true,
      where: "execution_run_id IS NOT NULL", name: "index_usage_cost_snapshots_unique_run"
    add_index :usage_cost_snapshots, :public_web_search_id, unique: true,
      where: "public_web_search_id IS NOT NULL", name: "index_usage_cost_snapshots_unique_search"
    add_foreign_key :usage_cost_snapshots, :execution_runs,
      column: [ :workspace_id, :execution_run_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_usage_cost_snapshots_run"
    add_foreign_key :usage_cost_snapshots, :public_web_searches,
      column: [ :workspace_id, :public_web_search_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_usage_cost_snapshots_search"
    add_foreign_key :usage_cost_snapshots, :usage_rate_versions,
      column: [ :workspace_id, :applied_usage_rate_version_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_usage_cost_snapshots_rate"
    add_check_constraint :usage_cost_snapshots,
      "(execution_run_id IS NOT NULL)::integer + (public_web_search_id IS NOT NULL)::integer = 1",
      name: "usage_cost_snapshots_subject"
    add_check_constraint :usage_cost_snapshots,
      "status IN ('complete', 'partial', 'unavailable', 'not_reported') AND " \
      "(source IS NULL OR source IN ('configured_rate', 'adapter_reported')) AND " \
      "(currency IS NULL OR currency ~ '^[A-Z]{3}$') AND " \
      "(amount_micros IS NULL OR amount_micros >= 0) AND " \
      "(observed_input_units IS NULL OR observed_input_units >= 0) AND " \
      "(observed_output_units IS NULL OR observed_output_units >= 0) AND " \
      "(observed_search_units IS NULL OR observed_search_units >= 0) AND " \
      "jsonb_typeof(calculation_provenance) = 'object' AND octet_length(calculation_provenance::text) <= 8192",
      name: "usage_cost_snapshots_values"
    add_check_constraint :usage_cost_snapshots,
      "(status IN ('complete', 'partial') AND source IS NOT NULL AND currency IS NOT NULL AND amount_micros IS NOT NULL) OR " \
      "(status IN ('unavailable', 'not_reported') AND source IS NULL AND currency IS NULL AND amount_micros IS NULL)",
      name: "usage_cost_snapshots_money_shape"
    add_check_constraint :usage_cost_snapshots,
      "source <> 'configured_rate' OR applied_usage_rate_version_id IS NOT NULL",
      name: "usage_cost_snapshots_rate_source"

    reversible do |direction|
      direction.up do
        backfill_unknown_snapshots
        protect_usage_records
      end
      direction.down do
        execute "DROP FUNCTION IF EXISTS protect_usage_rate_setting() CASCADE"
        execute "DROP FUNCTION IF EXISTS protect_usage_rate_version() CASCADE"
        execute "DROP FUNCTION IF EXISTS protect_usage_cost_snapshot() CASCADE"
        execute "DROP FUNCTION IF EXISTS protect_execution_usage_rate() CASCADE"
        execute "DROP FUNCTION IF EXISTS protect_public_web_search_usage_rate() CASCADE"
      end
    end
  end

  private
    def backfill_unknown_snapshots
      execute <<~SQL
        INSERT INTO usage_cost_snapshots (
          workspace_id, execution_run_id, status, observed_input_units, observed_output_units,
          calculation_provenance, captured_at, created_at, updated_at
        )
        SELECT runs.workspace_id, runs.id,
          CASE WHEN EXISTS (
            SELECT 1 FROM execution_events events
            WHERE events.execution_run_id = runs.id AND events.event_type = 'usage.observed'
          ) THEN 'unavailable' ELSE 'not_reported' END,
          CASE WHEN EXISTS (
            SELECT 1 FROM execution_events events
            WHERE events.execution_run_id = runs.id AND events.event_type = 'usage.observed'
          ) THEN runs.input_units ELSE NULL END,
          CASE WHEN EXISTS (
            SELECT 1 FROM execution_events events
            WHERE events.execution_run_id = runs.id AND events.event_type = 'usage.observed'
          ) THEN runs.output_units ELSE NULL END,
          jsonb_build_object('source', 'retained_execution_ledger', 'reason', 'no_frozen_rate'),
          COALESCE(runs.finished_at, runs.updated_at), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM execution_runs runs
        WHERE runs.status IN ('completed', 'failed', 'timed_out', 'canceled', 'policy_denied');

        INSERT INTO usage_cost_snapshots (
          workspace_id, public_web_search_id, status, observed_search_units,
          calculation_provenance, captured_at, created_at, updated_at
        )
        SELECT searches.workspace_id, searches.id,
          CASE searches.status WHEN 'completed' THEN 'unavailable' ELSE 'not_reported' END,
          CASE searches.status WHEN 'completed' THEN searches.cost_units ELSE NULL END,
          jsonb_build_object('source', 'retained_search_ledger', 'reason', 'no_frozen_rate'),
          COALESCE(searches.retrieved_at, searches.updated_at), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM public_web_searches searches
        WHERE searches.status IN ('completed', 'failed');
      SQL
    end

    def protect_usage_records
      execute <<~SQL
        CREATE FUNCTION protect_usage_rate_setting()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
            RETURN OLD;
          END IF;
          IF TG_OP <> 'UPDATE' OR
             ROW(OLD.id, OLD.workspace_id, OLD.created_at) IS DISTINCT FROM
             ROW(NEW.id, NEW.workspace_id, NEW.created_at) THEN
            RAISE EXCEPTION 'usage rate setting identity is durable';
          END IF;
          RETURN NEW;
        END;
        $$;
        CREATE TRIGGER usage_rate_settings_protect
        BEFORE UPDATE OR DELETE ON usage_rate_settings
        FOR EACH ROW EXECUTE FUNCTION protect_usage_rate_setting();
        CREATE TRIGGER usage_rate_settings_no_truncate
        BEFORE TRUNCATE ON usage_rate_settings
        FOR EACH STATEMENT EXECUTE FUNCTION protect_usage_rate_setting();

        CREATE FUNCTION protect_usage_rate_version()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
            RETURN OLD;
          END IF;
          RAISE EXCEPTION 'usage rate versions are append only';
        END;
        $$;
        CREATE TRIGGER usage_rate_versions_append_only
        BEFORE UPDATE OR DELETE ON usage_rate_versions
        FOR EACH ROW EXECUTE FUNCTION protect_usage_rate_version();
        CREATE TRIGGER usage_rate_versions_no_truncate
        BEFORE TRUNCATE ON usage_rate_versions
        FOR EACH STATEMENT EXECUTE FUNCTION protect_usage_rate_version();

        CREATE FUNCTION protect_usage_cost_snapshot()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
            RETURN OLD;
          END IF;
          RAISE EXCEPTION 'usage cost snapshots are append only';
        END;
        $$;
        CREATE TRIGGER usage_cost_snapshots_append_only
        BEFORE UPDATE OR DELETE ON usage_cost_snapshots
        FOR EACH ROW EXECUTE FUNCTION protect_usage_cost_snapshot();
        CREATE TRIGGER usage_cost_snapshots_no_truncate
        BEFORE TRUNCATE ON usage_cost_snapshots
        FOR EACH STATEMENT EXECUTE FUNCTION protect_usage_cost_snapshot();

        CREATE FUNCTION protect_execution_usage_rate()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF OLD.usage_rate_version_id IS DISTINCT FROM NEW.usage_rate_version_id THEN
            RAISE EXCEPTION 'execution run usage rate is immutable';
          END IF;
          RETURN NEW;
        END;
        $$;
        CREATE TRIGGER execution_runs_usage_rate_immutable
        BEFORE UPDATE ON execution_runs
        FOR EACH ROW EXECUTE FUNCTION protect_execution_usage_rate();

        CREATE FUNCTION protect_public_web_search_usage_rate()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF OLD.usage_rate_version_id IS DISTINCT FROM NEW.usage_rate_version_id THEN
            RAISE EXCEPTION 'public web search usage rate is immutable';
          END IF;
          RETURN NEW;
        END;
        $$;
        CREATE TRIGGER public_web_searches_usage_rate_immutable
        BEFORE UPDATE ON public_web_searches
        FOR EACH ROW EXECUTE FUNCTION protect_public_web_search_usage_rate();
      SQL
    end
end
