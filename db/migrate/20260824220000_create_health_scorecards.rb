class CreateHealthScorecards < ActiveRecord::Migration[8.1]
  DEFAULT_DEFINITION = {
    "schema_version" => 1,
    "healthy_min" => 75,
    "watch_min" => 50,
    "rules" => [
      { "signal_key" => "open_cases", "weight" => 20 },
      { "signal_key" => "sla_breaches", "weight" => 25 },
      { "signal_key" => "customer_inactivity_days", "weight" => 20 },
      { "signal_key" => "renewal_on", "weight" => 25 },
      { "signal_key" => "seat_utilization_percent", "weight" => 15 }
    ]
  }.freeze

  def change
    create_table :health_scorecards do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :name, null: false
      t.bigint :current_version_id
      t.timestamps
    end
    add_index :health_scorecards, :workspace_id, unique: true
    add_index :health_scorecards, [ :workspace_id, :id ], unique: true

    create_table :health_scorecard_versions do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :health_scorecard_id, null: false
      t.integer :version_number, null: false
      t.text :design_prompt, null: false
      t.text :explanation, null: false
      t.jsonb :definition, null: false, default: {}
      t.bigint :created_by_membership_id
      t.bigint :created_by_user_id
      t.timestamps
    end
    add_index :health_scorecard_versions, [ :health_scorecard_id, :version_number ], unique: true
    add_index :health_scorecard_versions, [ :workspace_id, :id ], unique: true
    add_index :health_scorecard_versions, [ :workspace_id, :health_scorecard_id, :id ], unique: true,
      name: "index_health_scorecard_versions_tenant_chain"
    add_foreign_key :health_scorecard_versions, :health_scorecards,
      column: [ :workspace_id, :health_scorecard_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :health_scorecard_versions, :memberships,
      column: [ :workspace_id, :created_by_membership_id, :created_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_health_scorecard_versions_actor"
    add_foreign_key :health_scorecard_versions, :users, column: :created_by_user_id
    add_foreign_key :health_scorecards, :health_scorecard_versions,
      column: [ :workspace_id, :id, :current_version_id ],
      primary_key: [ :workspace_id, :health_scorecard_id, :id ], name: "fk_health_scorecards_current_version"
    add_check_constraint :health_scorecard_versions, "version_number > 0",
      name: "health_scorecard_versions_number"
    add_check_constraint :health_scorecard_versions,
      "octet_length(design_prompt) BETWEEN 1 AND 4000 AND octet_length(explanation) BETWEEN 1 AND 8000",
      name: "health_scorecard_versions_content"
    add_check_constraint :health_scorecard_versions,
      "(created_by_membership_id IS NULL AND created_by_user_id IS NULL) OR " \
      "(created_by_membership_id IS NOT NULL AND created_by_user_id IS NOT NULL)",
      name: "health_scorecard_versions_actor"

    create_table :health_scorecard_design_turns do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :health_scorecard_id, null: false
      t.bigint :health_scorecard_version_id, null: false
      t.bigint :membership_id, null: false
      t.bigint :user_id, null: false
      t.text :prompt, null: false
      t.text :response, null: false
      t.timestamps
    end
    add_index :health_scorecard_design_turns, [ :workspace_id, :id ], unique: true
    add_foreign_key :health_scorecard_design_turns, :health_scorecards,
      column: [ :workspace_id, :health_scorecard_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :health_scorecard_design_turns, :health_scorecard_versions,
      column: [ :workspace_id, :health_scorecard_version_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :health_scorecard_design_turns, :memberships,
      column: [ :workspace_id, :membership_id, :user_id ], primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :health_scorecard_design_turns, :users, column: :user_id
    add_check_constraint :health_scorecard_design_turns,
      "octet_length(prompt) BETWEEN 1 AND 4000 AND octet_length(response) BETWEEN 1 AND 8000",
      name: "health_scorecard_design_turns_content"

    create_table :health_scorecard_backtests do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :health_scorecard_version_id, null: false
      t.bigint :membership_id, null: false
      t.bigint :user_id, null: false
      t.string :source_digest, null: false
      t.jsonb :results, null: false, default: {}
      t.integer :sample_count, null: false
      t.datetime :generated_at, null: false
      t.timestamps
    end
    add_index :health_scorecard_backtests, [ :workspace_id, :id ], unique: true
    add_index :health_scorecard_backtests, [ :health_scorecard_version_id, :created_at ]
    add_foreign_key :health_scorecard_backtests, :health_scorecard_versions,
      column: [ :workspace_id, :health_scorecard_version_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :health_scorecard_backtests, :memberships,
      column: [ :workspace_id, :membership_id, :user_id ], primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :health_scorecard_backtests, :users, column: :user_id
    add_check_constraint :health_scorecard_backtests, "source_digest ~ '^[0-9a-f]{64}$'",
      name: "health_scorecard_backtests_digest"
    add_check_constraint :health_scorecard_backtests, "sample_count BETWEEN 0 AND 500",
      name: "health_scorecard_backtests_sample_count"

    add_reference :account_health_assessments, :health_scorecard_version
    add_foreign_key :account_health_assessments, :health_scorecard_versions,
      column: [ :workspace_id, :health_scorecard_version_id ], primary_key: [ :workspace_id, :id ]

    reversible do |direction|
      direction.up do
        install_defaults
        protect_scorecards
      end
      direction.down do
        execute "ALTER TABLE account_health_assessments ALTER COLUMN health_scorecard_version_id DROP NOT NULL"
        execute "DROP FUNCTION IF EXISTS protect_health_scorecard_record() CASCADE"
      end
    end
  end

  private
    def install_defaults
      definition = connection.quote(DEFAULT_DEFINITION.to_json)
      execute <<~SQL
        INSERT INTO health_scorecards (workspace_id, name, created_at, updated_at)
        SELECT id, 'Account health', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM workspaces;

        INSERT INTO health_scorecard_versions (
          workspace_id, health_scorecard_id, version_number, design_prompt, explanation,
          definition, created_at, updated_at
        )
        SELECT workspace_id, id, 1, 'Use the NavishAI starting scorecard.',
          'Balances support load, SLA breaches, customer inactivity, renewal timing, and seat use.',
          #{definition}::jsonb, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM health_scorecards;

        UPDATE health_scorecards scorecard
        SET current_version_id = version.id, updated_at = CURRENT_TIMESTAMP
        FROM health_scorecard_versions version
        WHERE version.health_scorecard_id = scorecard.id AND version.version_number = 1;

        ALTER TABLE account_health_assessments DISABLE TRIGGER account_health_assessments_append_only;
        UPDATE account_health_assessments assessment
        SET health_scorecard_version_id = scorecard.current_version_id
        FROM health_scorecards scorecard
        WHERE scorecard.workspace_id = assessment.workspace_id;
        ALTER TABLE account_health_assessments ENABLE TRIGGER account_health_assessments_append_only;

        ALTER TABLE account_health_assessments ALTER COLUMN health_scorecard_version_id SET NOT NULL;
      SQL
    end

    def protect_scorecards
      execute <<~SQL
        DROP TRIGGER IF EXISTS account_health_inputs_no_truncate ON account_health_inputs;
        DROP TRIGGER IF EXISTS account_health_assessments_no_truncate ON account_health_assessments;
        DROP TRIGGER IF EXISTS account_health_signals_no_truncate ON account_health_signals;
        CREATE TRIGGER account_health_inputs_no_truncate BEFORE TRUNCATE ON account_health_inputs
          FOR EACH STATEMENT EXECUTE FUNCTION protect_account_health_snapshot();
        CREATE TRIGGER account_health_assessments_no_truncate BEFORE TRUNCATE ON account_health_assessments
          FOR EACH STATEMENT EXECUTE FUNCTION protect_account_health_snapshot();
        CREATE TRIGGER account_health_signals_no_truncate BEFORE TRUNCATE ON account_health_signals
          FOR EACH STATEMENT EXECUTE FUNCTION protect_account_health_snapshot();

        CREATE FUNCTION protect_health_scorecard_record()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
            RETURN OLD;
          END IF;
          IF TG_TABLE_NAME = 'health_scorecards' AND TG_OP = 'UPDATE' AND
             ROW(OLD.id, OLD.workspace_id, OLD.name, OLD.created_at)
               IS NOT DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.name, NEW.created_at) AND
             OLD.current_version_id IS DISTINCT FROM NEW.current_version_id THEN
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'health scorecard records are durable';
        END;
        $$;
        CREATE TRIGGER health_scorecards_protect BEFORE UPDATE OR DELETE ON health_scorecards
          FOR EACH ROW EXECUTE FUNCTION protect_health_scorecard_record();
        CREATE TRIGGER health_scorecards_no_truncate BEFORE TRUNCATE ON health_scorecards
          FOR EACH STATEMENT EXECUTE FUNCTION protect_health_scorecard_record();
        CREATE TRIGGER health_scorecard_versions_append_only BEFORE UPDATE OR DELETE ON health_scorecard_versions
          FOR EACH ROW EXECUTE FUNCTION protect_health_scorecard_record();
        CREATE TRIGGER health_scorecard_versions_no_truncate BEFORE TRUNCATE ON health_scorecard_versions
          FOR EACH STATEMENT EXECUTE FUNCTION protect_health_scorecard_record();
        CREATE TRIGGER health_scorecard_design_turns_append_only BEFORE UPDATE OR DELETE ON health_scorecard_design_turns
          FOR EACH ROW EXECUTE FUNCTION protect_health_scorecard_record();
        CREATE TRIGGER health_scorecard_design_turns_no_truncate BEFORE TRUNCATE ON health_scorecard_design_turns
          FOR EACH STATEMENT EXECUTE FUNCTION protect_health_scorecard_record();
        CREATE TRIGGER health_scorecard_backtests_append_only BEFORE UPDATE OR DELETE ON health_scorecard_backtests
          FOR EACH ROW EXECUTE FUNCTION protect_health_scorecard_record();
        CREATE TRIGGER health_scorecard_backtests_no_truncate BEFORE TRUNCATE ON health_scorecard_backtests
          FOR EACH STATEMENT EXECUTE FUNCTION protect_health_scorecard_record();
      SQL
    end
end
