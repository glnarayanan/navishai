class AllowInterventionFollowUpChanges < ActiveRecord::Migration[8.1]
  def up
    create_due_notices
    expand_notification_categories
    replace_intervention_guard
  end

  def down
    restore_intervention_guard
    restore_notification_categories
    drop_table :customer_success_intervention_due_notices
  end

  private
    def create_due_notices
      create_table :customer_success_intervention_due_notices do |t|
        t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
        t.bigint :customer_success_intervention_id, null: false
        t.bigint :recipient_membership_id, null: false
        t.string :due_state, null: false
        t.date :target_on, null: false
        t.bigint :source_audit_event_id, null: false
        t.datetime :notified_at, null: false
        t.timestamps
      end

      add_index :customer_success_intervention_due_notices, [ :workspace_id, :id ], unique: true,
        name: "index_cs_due_notices_on_workspace_id_and_id"
      add_index :customer_success_intervention_due_notices,
        [ :customer_success_intervention_id, :recipient_membership_id, :due_state, :target_on ],
        unique: true, name: "index_cs_due_notices_on_transition"
      add_foreign_key :customer_success_intervention_due_notices, :customer_success_interventions,
        column: [ :workspace_id, :customer_success_intervention_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_cs_due_notices_intervention"
      add_foreign_key :customer_success_intervention_due_notices, :memberships,
        column: [ :workspace_id, :recipient_membership_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_cs_due_notices_recipient"
      add_foreign_key :customer_success_intervention_due_notices, :audit_events,
        column: :source_audit_event_id, name: "fk_cs_due_notices_event"
      add_check_constraint :customer_success_intervention_due_notices,
        "due_state IN ('due', 'overdue')", name: "customer_success_intervention_due_notices_state"
    end

    def expand_notification_categories
      remove_check_constraint :notifications, name: "notifications_category"
      add_check_constraint :notifications,
        "category IN ('assignment', 'review', 'sla', 'failure', 'blocked', 'completion', 'due')",
        name: "notifications_category"
      remove_check_constraint :outbound_webhook_endpoints, name: "outbound_webhooks_categories"
      add_check_constraint :outbound_webhook_endpoints,
        "jsonb_typeof(categories) = 'array' AND jsonb_array_length(categories) BETWEEN 1 AND 7",
        name: "outbound_webhooks_categories"
    end

    def restore_notification_categories
      remove_check_constraint :outbound_webhook_endpoints, name: "outbound_webhooks_categories"
      add_check_constraint :outbound_webhook_endpoints,
        "jsonb_typeof(categories) = 'array' AND jsonb_array_length(categories) BETWEEN 1 AND 6",
        name: "outbound_webhooks_categories"
      remove_check_constraint :notifications, name: "notifications_category"
      add_check_constraint :notifications,
        "category IN ('assignment', 'review', 'sla', 'failure', 'blocked', 'completion')",
        name: "notifications_category"
    end

    def replace_intervention_guard
      execute <<~SQL
        CREATE OR REPLACE FUNCTION protect_customer_success_intervention()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'TRUNCATE' THEN
            RAISE EXCEPTION 'customer success interventions cannot be truncated';
          END IF;
          IF TG_OP = 'DELETE' THEN
            IF NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            RAISE EXCEPTION 'customer success interventions cannot be deleted';
          END IF;
          IF ROW(
            NEW.workspace_id, NEW.account_id, NEW.account_health_assessment_id,
            NEW.account_risk_investigation_id, NEW.proposing_crew_artifact_id,
            NEW.proposed_by_membership_id, NEW.supporting_evidence, NEW.expected_observable_change,
            NEW.reason, NEW.proposed_at, NEW.created_at
          ) IS DISTINCT FROM ROW(
            OLD.workspace_id, OLD.account_id, OLD.account_health_assessment_id,
            OLD.account_risk_investigation_id, OLD.proposing_crew_artifact_id,
            OLD.proposed_by_membership_id, OLD.supporting_evidence, OLD.expected_observable_change,
            OLD.reason, OLD.proposed_at, OLD.created_at
          ) THEN
            RAISE EXCEPTION 'customer success intervention provenance is immutable';
          END IF;
          IF OLD.status = 'proposed' AND NEW.status = 'approved' THEN
            IF ROW(NEW.accountable_membership_id, NEW.target_on) IS DISTINCT FROM
                ROW(OLD.accountable_membership_id, OLD.target_on) OR
                NEW.approved_by_membership_id IS NULL OR NEW.approved_at IS NULL OR
                NEW.completed_by_membership_id IS NOT NULL OR NEW.completed_at IS NOT NULL OR
                NEW.abandoned_by_membership_id IS NOT NULL OR NEW.abandoned_at IS NOT NULL OR
                NEW.abandonment_reason IS NOT NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention approval';
            END IF;
          ELSIF OLD.status = 'proposed' AND NEW.status = 'abandoned' THEN
            IF ROW(NEW.accountable_membership_id, NEW.target_on) IS DISTINCT FROM
                ROW(OLD.accountable_membership_id, OLD.target_on) OR
                NEW.approved_by_membership_id IS NOT NULL OR NEW.approved_at IS NOT NULL OR
                NEW.completed_by_membership_id IS NOT NULL OR NEW.completed_at IS NOT NULL OR
                NEW.abandoned_by_membership_id IS NULL OR NEW.abandoned_at IS NULL OR
                NEW.abandonment_reason IS NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention abandonment';
            END IF;
          ELSIF OLD.status = 'approved' AND NEW.status = 'completed' THEN
            IF ROW(NEW.approved_by_membership_id, NEW.approved_at, NEW.accountable_membership_id, NEW.target_on)
                IS DISTINCT FROM ROW(OLD.approved_by_membership_id, OLD.approved_at,
                OLD.accountable_membership_id, OLD.target_on) OR
                NEW.completed_by_membership_id IS NULL OR NEW.completed_at IS NULL OR
                NEW.abandoned_by_membership_id IS NOT NULL OR NEW.abandoned_at IS NOT NULL OR
                NEW.abandonment_reason IS NOT NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention completion';
            END IF;
          ELSIF OLD.status = 'approved' AND NEW.status = 'abandoned' THEN
            IF ROW(NEW.approved_by_membership_id, NEW.approved_at, NEW.accountable_membership_id, NEW.target_on)
                IS DISTINCT FROM ROW(OLD.approved_by_membership_id, OLD.approved_at,
                OLD.accountable_membership_id, OLD.target_on) OR
                NEW.completed_by_membership_id IS NOT NULL OR NEW.completed_at IS NOT NULL OR
                NEW.abandoned_by_membership_id IS NULL OR NEW.abandoned_at IS NULL OR
                NEW.abandonment_reason IS NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention abandonment';
            END IF;
          ELSIF OLD.status = 'completed' AND NEW.status = 'reviewed' THEN
            IF ROW(
                NEW.approved_by_membership_id, NEW.approved_at,
                NEW.completed_by_membership_id, NEW.completed_at,
                NEW.accountable_membership_id, NEW.target_on
              ) IS DISTINCT FROM ROW(
                OLD.approved_by_membership_id, OLD.approved_at,
                OLD.completed_by_membership_id, OLD.completed_at,
                OLD.accountable_membership_id, OLD.target_on
              ) OR NOT EXISTS (
                SELECT 1 FROM customer_success_intervention_outcome_reviews
                WHERE customer_success_intervention_id = NEW.id AND workspace_id = NEW.workspace_id
              ) THEN
              RAISE EXCEPTION 'invalid customer success intervention outcome review';
            END IF;
          ELSIF OLD.status IN ('proposed', 'approved') AND NEW.status = OLD.status THEN
            IF ROW(
                NEW.approved_by_membership_id, NEW.approved_at,
                NEW.completed_by_membership_id, NEW.completed_at,
                NEW.abandoned_by_membership_id, NEW.abandoned_at, NEW.abandonment_reason
              ) IS DISTINCT FROM ROW(
                OLD.approved_by_membership_id, OLD.approved_at,
                OLD.completed_by_membership_id, OLD.completed_at,
                OLD.abandoned_by_membership_id, OLD.abandoned_at, OLD.abandonment_reason
              ) OR ROW(NEW.accountable_membership_id, NEW.target_on) IS NOT DISTINCT FROM
                ROW(OLD.accountable_membership_id, OLD.target_on) OR
                NEW.target_on < (NEW.proposed_at)::date THEN
              RAISE EXCEPTION 'invalid customer success intervention follow-up change';
            END IF;
          ELSE
            RAISE EXCEPTION 'invalid customer success intervention transition';
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end

    def restore_intervention_guard
      execute <<~SQL
        CREATE OR REPLACE FUNCTION protect_customer_success_intervention()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'TRUNCATE' THEN
            RAISE EXCEPTION 'customer success interventions cannot be truncated';
          END IF;
          IF TG_OP = 'DELETE' THEN
            IF NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            RAISE EXCEPTION 'customer success interventions cannot be deleted';
          END IF;
          IF ROW(
            NEW.workspace_id, NEW.account_id, NEW.account_health_assessment_id,
            NEW.account_risk_investigation_id, NEW.proposing_crew_artifact_id,
            NEW.accountable_membership_id, NEW.proposed_by_membership_id,
            NEW.supporting_evidence, NEW.expected_observable_change, NEW.target_on,
            NEW.reason, NEW.proposed_at, NEW.created_at
          ) IS DISTINCT FROM ROW(
            OLD.workspace_id, OLD.account_id, OLD.account_health_assessment_id,
            OLD.account_risk_investigation_id, OLD.proposing_crew_artifact_id,
            OLD.accountable_membership_id, OLD.proposed_by_membership_id,
            OLD.supporting_evidence, OLD.expected_observable_change, OLD.target_on,
            OLD.reason, OLD.proposed_at, OLD.created_at
          ) THEN
            RAISE EXCEPTION 'customer success intervention provenance is immutable';
          END IF;
          IF OLD.status = 'proposed' AND NEW.status = 'approved' THEN
            IF NEW.approved_by_membership_id IS NULL OR NEW.approved_at IS NULL OR
                NEW.completed_by_membership_id IS NOT NULL OR NEW.completed_at IS NOT NULL OR
                NEW.abandoned_by_membership_id IS NOT NULL OR NEW.abandoned_at IS NOT NULL OR
                NEW.abandonment_reason IS NOT NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention approval';
            END IF;
          ELSIF OLD.status = 'proposed' AND NEW.status = 'abandoned' THEN
            IF NEW.approved_by_membership_id IS NOT NULL OR NEW.approved_at IS NOT NULL OR
                NEW.completed_by_membership_id IS NOT NULL OR NEW.completed_at IS NOT NULL OR
                NEW.abandoned_by_membership_id IS NULL OR NEW.abandoned_at IS NULL OR
                NEW.abandonment_reason IS NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention abandonment';
            END IF;
          ELSIF OLD.status = 'approved' AND NEW.status = 'completed' THEN
            IF ROW(NEW.approved_by_membership_id, NEW.approved_at) IS DISTINCT FROM
                ROW(OLD.approved_by_membership_id, OLD.approved_at) OR
                NEW.completed_by_membership_id IS NULL OR NEW.completed_at IS NULL OR
                NEW.abandoned_by_membership_id IS NOT NULL OR NEW.abandoned_at IS NOT NULL OR
                NEW.abandonment_reason IS NOT NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention completion';
            END IF;
          ELSIF OLD.status = 'approved' AND NEW.status = 'abandoned' THEN
            IF ROW(NEW.approved_by_membership_id, NEW.approved_at) IS DISTINCT FROM
                ROW(OLD.approved_by_membership_id, OLD.approved_at) OR
                NEW.completed_by_membership_id IS NOT NULL OR NEW.completed_at IS NOT NULL OR
                NEW.abandoned_by_membership_id IS NULL OR NEW.abandoned_at IS NULL OR
                NEW.abandonment_reason IS NULL THEN
              RAISE EXCEPTION 'invalid customer success intervention abandonment';
            END IF;
          ELSIF OLD.status = 'completed' AND NEW.status = 'reviewed' THEN
            IF ROW(
                NEW.approved_by_membership_id, NEW.approved_at,
                NEW.completed_by_membership_id, NEW.completed_at
              ) IS DISTINCT FROM ROW(
                OLD.approved_by_membership_id, OLD.approved_at,
                OLD.completed_by_membership_id, OLD.completed_at
              ) OR NOT EXISTS (
                SELECT 1 FROM customer_success_intervention_outcome_reviews
                WHERE customer_success_intervention_id = NEW.id AND workspace_id = NEW.workspace_id
              ) THEN
              RAISE EXCEPTION 'invalid customer success intervention outcome review';
            END IF;
          ELSE
            RAISE EXCEPTION 'invalid customer success intervention transition';
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end
end
