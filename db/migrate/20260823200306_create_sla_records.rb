class CreateSlaRecords < ActiveRecord::Migration[8.1]
  def change
    create_service_calendars
    create_sla_policies
    create_case_slas
    create_sla_escalation_tasks
    protect_used_configuration
  end

  private
    def create_service_calendars
      create_table :service_calendars do |t|
        t.references :workspace, null: false, foreign_key: true
        t.string :name, null: false
        t.string :time_zone, null: false
        t.jsonb :weekly_hours, null: false, default: {}
        t.timestamps
      end
      add_index :service_calendars, [ :workspace_id, :id ], unique: true
      add_index :service_calendars, [ :workspace_id, :name ], unique: true

      create_table :service_calendar_holidays do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :service_calendar_id, null: false
        t.date :date, null: false
        t.string :name, null: false
        t.timestamps
      end
      add_index :service_calendar_holidays, [ :workspace_id, :id ], unique: true
      add_index :service_calendar_holidays, [ :service_calendar_id, :date ], unique: true
      add_foreign_key :service_calendar_holidays, :service_calendars,
        column: [ :workspace_id, :service_calendar_id ],
        primary_key: [ :workspace_id, :id ]
    end

    def create_sla_policies
      create_table :sla_policies do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :service_calendar_id, null: false
        t.string :name, null: false
        t.string :priority, null: false
        t.integer :first_response_minutes, null: false
        t.integer :resolution_minutes, null: false
        t.integer :warning_percent, null: false, default: 80
        t.boolean :active, null: false, default: true
        t.timestamps
      end
      add_index :sla_policies, [ :workspace_id, :id ], unique: true
      add_index :sla_policies, [ :workspace_id, :priority ], unique: true, where: "active", name: "index_active_sla_policies_on_priority"
      add_foreign_key :sla_policies, :service_calendars,
        column: [ :workspace_id, :service_calendar_id ],
        primary_key: [ :workspace_id, :id ]
      add_check_constraint :sla_policies, "priority IN ('low', 'normal', 'high', 'urgent')", name: "sla_policies_priority"
      add_check_constraint :sla_policies, "first_response_minutes > 0 AND resolution_minutes > 0", name: "sla_policies_positive_targets"
      add_check_constraint :sla_policies, "warning_percent BETWEEN 1 AND 99", name: "sla_policies_warning_percent"
    end

    def create_case_slas
      create_table :case_slas do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :support_case_id, null: false
        t.bigint :sla_policy_id, null: false
        t.datetime :started_at, null: false
        t.datetime :first_response_warning_at, null: false
        t.datetime :first_response_due_at, null: false
        t.datetime :resolution_warning_at, null: false
        t.datetime :resolution_due_at, null: false
        t.string :first_response_status, null: false, default: "pending"
        t.string :resolution_status, null: false, default: "pending"
        t.datetime :first_responded_at
        t.datetime :resolved_at
        t.datetime :paused_at
        t.integer :paused_business_seconds, null: false, default: 0
        t.timestamps
      end
      add_index :case_slas, [ :workspace_id, :id ], unique: true
      add_index :case_slas, [ :workspace_id, :support_case_id ], unique: true
      add_index :case_slas, [ :workspace_id, :first_response_status, :first_response_warning_at ], name: "index_case_slas_on_first_response_clock"
      add_index :case_slas, [ :workspace_id, :resolution_status, :resolution_warning_at ], name: "index_case_slas_on_resolution_clock"
      add_foreign_key :case_slas, :support_cases,
        column: [ :workspace_id, :support_case_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :case_slas, :sla_policies,
        column: [ :workspace_id, :sla_policy_id ],
        primary_key: [ :workspace_id, :id ]
      add_check_constraint :case_slas, "first_response_status IN ('pending', 'met', 'breached')", name: "case_slas_first_response_status"
      add_check_constraint :case_slas, "resolution_status IN ('pending', 'met', 'breached')", name: "case_slas_resolution_status"
      add_check_constraint :case_slas, "paused_business_seconds >= 0", name: "case_slas_paused_seconds"
      add_check_constraint :case_slas, "first_response_warning_at < first_response_due_at AND resolution_warning_at < resolution_due_at", name: "case_slas_warning_before_due"
      add_check_constraint :case_slas, "(first_response_status != 'met' OR first_responded_at IS NOT NULL) AND (first_responded_at IS NULL OR first_response_status != 'pending')", name: "case_slas_first_response_completion"
      add_check_constraint :case_slas, "(resolution_status != 'met' OR resolved_at IS NOT NULL) AND (resolved_at IS NULL OR resolution_status != 'pending')", name: "case_slas_resolution_completion"
    end

    def create_sla_escalation_tasks
      create_table :sla_escalation_tasks do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :case_sla_id, null: false
        t.string :objective, null: false
        t.string :kind, null: false
        t.string :status, null: false, default: "open"
        t.datetime :occurred_at, null: false
        t.timestamps
      end
      add_index :sla_escalation_tasks, [ :workspace_id, :id ], unique: true
      add_index :sla_escalation_tasks, [ :case_sla_id, :objective, :kind ], unique: true, name: "index_sla_escalation_tasks_on_event"
      add_foreign_key :sla_escalation_tasks, :case_slas,
        column: [ :workspace_id, :case_sla_id ],
        primary_key: [ :workspace_id, :id ]
      add_check_constraint :sla_escalation_tasks, "objective IN ('first_response', 'resolution')", name: "sla_escalation_tasks_objective"
      add_check_constraint :sla_escalation_tasks, "kind IN ('warning', 'breach')", name: "sla_escalation_tasks_kind"
      add_check_constraint :sla_escalation_tasks, "status IN ('open', 'completed')", name: "sla_escalation_tasks_status"
    end

    def protect_used_configuration
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION prevent_used_sla_configuration_change()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            DECLARE
              referenced boolean;
              calendar_id bigint;
            BEGIN
              IF TG_TABLE_NAME = 'sla_policies' THEN
                SELECT EXISTS (SELECT 1 FROM case_slas WHERE sla_policy_id = OLD.id) INTO referenced;
                IF referenced AND (TG_OP = 'DELETE' OR
                   OLD.workspace_id IS DISTINCT FROM NEW.workspace_id OR
                   OLD.service_calendar_id IS DISTINCT FROM NEW.service_calendar_id OR
                   OLD.priority IS DISTINCT FROM NEW.priority OR
                   OLD.first_response_minutes IS DISTINCT FROM NEW.first_response_minutes OR
                   OLD.resolution_minutes IS DISTINCT FROM NEW.resolution_minutes OR
                   OLD.warning_percent IS DISTINCT FROM NEW.warning_percent) THEN
                  RAISE EXCEPTION 'used SLA policy settings are immutable';
                END IF;
              ELSIF TG_TABLE_NAME = 'service_calendars' THEN
                SELECT EXISTS (
                  SELECT 1 FROM case_slas
                  JOIN sla_policies ON sla_policies.id = case_slas.sla_policy_id
                  WHERE sla_policies.service_calendar_id = OLD.id
                ) INTO referenced;
                IF referenced AND (TG_OP = 'DELETE' OR
                   OLD.workspace_id IS DISTINCT FROM NEW.workspace_id OR
                   OLD.time_zone IS DISTINCT FROM NEW.time_zone OR
                   OLD.weekly_hours IS DISTINCT FROM NEW.weekly_hours) THEN
                  RAISE EXCEPTION 'used service calendar settings are immutable';
                END IF;
              ELSE
                IF TG_OP = 'UPDATE' THEN
                  PERFORM 1 FROM service_calendars
                  WHERE id IN (OLD.service_calendar_id, NEW.service_calendar_id)
                  ORDER BY id FOR UPDATE;
                  SELECT EXISTS (
                    SELECT 1 FROM case_slas
                    JOIN sla_policies ON sla_policies.id = case_slas.sla_policy_id
                    WHERE sla_policies.service_calendar_id IN (OLD.service_calendar_id, NEW.service_calendar_id)
                  ) INTO referenced;
                ELSE
                  calendar_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.service_calendar_id ELSE OLD.service_calendar_id END;
                  PERFORM 1 FROM service_calendars WHERE id = calendar_id FOR UPDATE;
                  SELECT EXISTS (
                    SELECT 1 FROM case_slas
                    JOIN sla_policies ON sla_policies.id = case_slas.sla_policy_id
                    WHERE sla_policies.service_calendar_id = calendar_id
                  ) INTO referenced;
                END IF;
                IF referenced THEN
                  RAISE EXCEPTION 'holidays on a used service calendar are immutable';
                END IF;
              END IF;
              IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
              RETURN NEW;
            END;
            $$;

            CREATE TRIGGER sla_policies_protect_used_settings
            BEFORE UPDATE OR DELETE ON sla_policies
            FOR EACH ROW EXECUTE FUNCTION prevent_used_sla_configuration_change();
            CREATE TRIGGER service_calendars_protect_used_settings
            BEFORE UPDATE OR DELETE ON service_calendars
            FOR EACH ROW EXECUTE FUNCTION prevent_used_sla_configuration_change();
            CREATE TRIGGER service_calendar_holidays_protect_used_settings
            BEFORE INSERT OR UPDATE OR DELETE ON service_calendar_holidays
            FOR EACH ROW EXECUTE FUNCTION prevent_used_sla_configuration_change();
          SQL
        end

        direction.down do
          execute "DROP TRIGGER IF EXISTS service_calendar_holidays_protect_used_settings ON service_calendar_holidays"
          execute "DROP TRIGGER IF EXISTS service_calendars_protect_used_settings ON service_calendars"
          execute "DROP TRIGGER IF EXISTS sla_policies_protect_used_settings ON sla_policies"
          execute "DROP FUNCTION IF EXISTS prevent_used_sla_configuration_change()"
        end
      end
    end
end
