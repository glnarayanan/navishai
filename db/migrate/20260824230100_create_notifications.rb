class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :recipient_membership, null: false, foreign_key: { to_table: :memberships }
      t.references :source_audit_event, null: false
      t.string :category, null: false
      t.string :title, null: false
      t.string :path, null: false
      t.datetime :occurred_at, null: false
      t.datetime :read_at
      t.timestamps
    end

    add_index :notifications, [ :recipient_membership_id, :source_audit_event_id ], unique: true,
      name: "index_notifications_on_recipient_and_event"
    add_index :notifications, [ :recipient_membership_id, :read_at, :occurred_at ],
      name: "index_notifications_inbox"
    add_check_constraint :notifications, "category IN ('assignment', 'review', 'sla', 'failure', 'blocked', 'completion')",
      name: "notifications_category"
    add_check_constraint :notifications, "octet_length(title) BETWEEN 1 AND 200", name: "notifications_title"
    add_check_constraint :notifications, "path ~ '^/[^/]' AND octet_length(path) <= 1000", name: "notifications_path"
    add_check_constraint :notifications, "read_at IS NULL OR read_at >= occurred_at", name: "notifications_read_time"

    add_foreign_key :notifications, :memberships,
      column: [ :workspace_id, :recipient_membership_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_notifications_workspace_recipient"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION enforce_notification_event_workspace()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF NOT EXISTS (
              SELECT 1 FROM audit_events
              WHERE id = NEW.source_audit_event_id AND workspace_id = NEW.workspace_id
            ) THEN
              RAISE EXCEPTION 'notification audit event belongs to another workspace';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER notifications_require_workspace_event
          BEFORE INSERT OR UPDATE ON notifications
          FOR EACH ROW EXECUTE FUNCTION enforce_notification_event_workspace();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER notifications_require_workspace_event ON notifications"
        execute "DROP FUNCTION enforce_notification_event_workspace()"
      end
    end
  end
end
