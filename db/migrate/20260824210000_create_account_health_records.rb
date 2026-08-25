class CreateAccountHealthRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :account_health_inputs do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :account_id, null: false
      t.string :input_key, null: false
      t.string :value_kind, null: false
      t.decimal :numeric_value, precision: 18, scale: 4
      t.date :date_value
      t.string :source_kind, null: false
      t.string :source_key, null: false
      t.string :source_locator, null: false
      t.datetime :observed_at, null: false
      t.bigint :supplied_by_membership_id
      t.bigint :supplied_by_user_id
      t.timestamps
    end
    add_index :account_health_inputs, [ :workspace_id, :account_id, :input_key, :observed_at ],
      name: "index_account_health_inputs_for_latest"
    add_index :account_health_inputs, [ :workspace_id, :source_kind, :source_key, :input_key ],
      unique: true, name: "index_account_health_inputs_on_source"
    add_index :account_health_inputs, [ :workspace_id, :id ], unique: true
    add_foreign_key :account_health_inputs, :accounts,
      column: [ :workspace_id, :account_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :account_health_inputs, :memberships,
      column: [ :workspace_id, :supplied_by_membership_id, :supplied_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_account_health_inputs_supplier"
    add_foreign_key :account_health_inputs, :users, column: :supplied_by_user_id
    add_check_constraint :account_health_inputs,
      "input_key IN ('renewal_on', 'contract_value', 'active_users', 'licensed_seats')",
      name: "account_health_inputs_key"
    add_check_constraint :account_health_inputs,
      "value_kind IN ('date', 'number') AND " \
      "((value_kind = 'date' AND date_value IS NOT NULL AND numeric_value IS NULL) OR " \
      "(value_kind = 'number' AND numeric_value IS NOT NULL AND date_value IS NULL))",
      name: "account_health_inputs_typed_value"
    add_check_constraint :account_health_inputs, "source_kind IN ('csv', 'api')",
      name: "account_health_inputs_source_kind"
    add_check_constraint :account_health_inputs,
      "octet_length(source_key) BETWEEN 1 AND 255 AND octet_length(source_locator) BETWEEN 1 AND 1000",
      name: "account_health_inputs_source"
    add_check_constraint :account_health_inputs,
      "(supplied_by_membership_id IS NULL AND supplied_by_user_id IS NULL) OR " \
      "(supplied_by_membership_id IS NOT NULL AND supplied_by_user_id IS NOT NULL)",
      name: "account_health_inputs_supplier"

    create_table :account_health_assessments do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :account_id, null: false
      t.bigint :previous_assessment_id
      t.integer :score, null: false
      t.string :risk_level, null: false
      t.string :trigger_kind, null: false
      t.boolean :material_change, null: false
      t.date :renewal_on
      t.datetime :calculated_at, null: false
      t.timestamps
    end
    add_index :account_health_assessments, [ :workspace_id, :account_id, :calculated_at ],
      name: "index_account_health_assessments_for_latest"
    add_index :account_health_assessments, [ :workspace_id, :id ], unique: true
    add_foreign_key :account_health_assessments, :accounts,
      column: [ :workspace_id, :account_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :account_health_assessments, :account_health_assessments,
      column: [ :workspace_id, :previous_assessment_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_account_health_assessments_previous"
    add_check_constraint :account_health_assessments, "score BETWEEN 0 AND 100",
      name: "account_health_assessments_score"
    add_check_constraint :account_health_assessments, "risk_level IN ('healthy', 'watch', 'at_risk')",
      name: "account_health_assessments_risk"
    add_check_constraint :account_health_assessments,
      "trigger_kind IN ('input_change', 'schedule', 'renewal_window', 'human_request')",
      name: "account_health_assessments_trigger"

    create_table :account_health_signals do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :account_health_assessment_id, null: false
      t.string :signal_key, null: false
      t.string :value_kind, null: false
      t.decimal :numeric_value, precision: 18, scale: 4
      t.date :date_value
      t.integer :weight, null: false
      t.integer :risk_points, null: false
      t.string :source_kind, null: false
      t.string :source_locator, null: false
      t.datetime :range_starts_at
      t.datetime :range_ends_at, null: false
      t.timestamps
    end
    add_index :account_health_signals, [ :account_health_assessment_id, :signal_key ], unique: true,
      name: "index_account_health_signals_unique"
    add_index :account_health_signals, [ :workspace_id, :id ], unique: true
    add_foreign_key :account_health_signals, :account_health_assessments,
      column: [ :workspace_id, :account_health_assessment_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_account_health_signals_assessment"
    add_check_constraint :account_health_signals,
      "value_kind IN ('date', 'number') AND " \
      "((value_kind = 'date' AND date_value IS NOT NULL AND numeric_value IS NULL) OR " \
      "(value_kind = 'number' AND numeric_value IS NOT NULL AND date_value IS NULL))",
      name: "account_health_signals_typed_value"
    add_check_constraint :account_health_signals, "weight BETWEEN 0 AND 100 AND risk_points BETWEEN 0 AND weight",
      name: "account_health_signals_weight"
    add_check_constraint :account_health_signals,
      "source_kind IN ('account_input', 'support_cases', 'sla', 'conversation', 'case_notes')",
      name: "account_health_signals_source_kind"
    add_check_constraint :account_health_signals, "octet_length(source_locator) BETWEEN 1 AND 1000",
      name: "account_health_signals_source"

    create_table :account_risk_investigations do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :account_id, null: false
      t.bigint :account_health_assessment_id, null: false
      t.bigint :crew_task_id
      t.string :status, null: false, default: "detected"
      t.string :trigger_kind, null: false
      t.datetime :opened_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :account_risk_investigations, :account_health_assessment_id, unique: true,
      name: "index_account_risk_investigations_on_assessment"
    add_index :account_risk_investigations, [ :workspace_id, :account_id, :status ],
      name: "index_account_risk_investigations_open"
    add_index :account_risk_investigations, [ :workspace_id, :id ], unique: true
    add_foreign_key :account_risk_investigations, :accounts,
      column: [ :workspace_id, :account_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :account_risk_investigations, :account_health_assessments,
      column: [ :workspace_id, :account_health_assessment_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_account_risk_investigations_assessment"
    add_foreign_key :account_risk_investigations, :crew_tasks,
      column: [ :workspace_id, :crew_task_id ], primary_key: [ :workspace_id, :id ]
    add_check_constraint :account_risk_investigations, "status IN ('detected', 'investigating', 'resolved')",
      name: "account_risk_investigations_status"
    add_check_constraint :account_risk_investigations,
      "trigger_kind IN ('material_change', 'renewal_window', 'human_request')",
      name: "account_risk_investigations_trigger"
    add_check_constraint :account_risk_investigations,
      "(status = 'detected' AND crew_task_id IS NULL AND resolved_at IS NULL) OR " \
      "(status = 'investigating' AND crew_task_id IS NOT NULL AND resolved_at IS NULL) OR " \
      "(status = 'resolved' AND crew_task_id IS NOT NULL AND resolved_at IS NOT NULL)",
      name: "account_risk_investigations_state"

    extend_crew_artifact_kinds
    protect_snapshots
  end

  private
    def extend_crew_artifact_kinds
      reversible do |direction|
        direction.up do
          remove_check_constraint :crew_artifacts, name: "crew_artifacts_kind"
          add_check_constraint :crew_artifacts,
            "artifact_kind IN ('investigation', 'draft', 'quality_review', 'account_analysis', " \
            "'risk_investigation', 'intervention_plan', 'success_review')",
            name: "crew_artifacts_kind"
          remove_check_constraint :crew_artifacts, name: "crew_artifacts_review_shape"
          add_check_constraint :crew_artifacts,
            "(artifact_kind IN ('quality_review', 'success_review') AND target_artifact_id IS NOT NULL AND review_outcome IS NOT NULL) OR " \
            "(artifact_kind NOT IN ('quality_review', 'success_review') AND target_artifact_id IS NULL AND review_outcome IS NULL)",
            name: "crew_artifacts_review_shape"
        end
        direction.down do
          remove_check_constraint :crew_artifacts, name: "crew_artifacts_review_shape"
          add_check_constraint :crew_artifacts,
            "(artifact_kind = 'quality_review' AND target_artifact_id IS NOT NULL AND review_outcome IS NOT NULL) OR " \
            "(artifact_kind <> 'quality_review' AND target_artifact_id IS NULL AND review_outcome IS NULL)",
            name: "crew_artifacts_review_shape"
          remove_check_constraint :crew_artifacts, name: "crew_artifacts_kind"
          add_check_constraint :crew_artifacts,
            "artifact_kind IN ('investigation', 'draft', 'quality_review')", name: "crew_artifacts_kind"
        end
      end
    end

    def protect_snapshots
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION protect_account_health_snapshot()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
                RETURN OLD;
              END IF;
              RAISE EXCEPTION 'account health records are append only';
            END;
            $$;
            CREATE TRIGGER account_health_inputs_append_only BEFORE UPDATE OR DELETE ON account_health_inputs
              FOR EACH ROW EXECUTE FUNCTION protect_account_health_snapshot();
            CREATE TRIGGER account_health_assessments_append_only BEFORE UPDATE OR DELETE ON account_health_assessments
              FOR EACH ROW EXECUTE FUNCTION protect_account_health_snapshot();
            CREATE TRIGGER account_health_signals_append_only BEFORE UPDATE OR DELETE ON account_health_signals
              FOR EACH ROW EXECUTE FUNCTION protect_account_health_snapshot();
            CREATE TRIGGER account_health_inputs_no_truncate BEFORE TRUNCATE ON account_health_inputs
              FOR EACH STATEMENT EXECUTE FUNCTION protect_account_health_snapshot();
            CREATE TRIGGER account_health_assessments_no_truncate BEFORE TRUNCATE ON account_health_assessments
              FOR EACH STATEMENT EXECUTE FUNCTION protect_account_health_snapshot();
            CREATE TRIGGER account_health_signals_no_truncate BEFORE TRUNCATE ON account_health_signals
              FOR EACH STATEMENT EXECUTE FUNCTION protect_account_health_snapshot();
          SQL
        end
        direction.down { execute "DROP FUNCTION IF EXISTS protect_account_health_snapshot() CASCADE" }
      end
    end
end
