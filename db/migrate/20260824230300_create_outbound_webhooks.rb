class CreateOutboundWebhooks < ActiveRecord::Migration[8.1]
  def change
    add_index :notifications, [ :workspace_id, :id ], unique: true, name: "index_notifications_on_workspace_and_id"

    create_table :outbound_webhook_endpoints do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :url, null: false
      t.string :credential_key, null: false
      t.boolean :active, null: false, default: true
      t.jsonb :categories, null: false, default: []
      t.timestamps
    end
    add_index :outbound_webhook_endpoints, [ :workspace_id, :name ], unique: true
    add_index :outbound_webhook_endpoints, [ :workspace_id, :id ], unique: true
    add_check_constraint :outbound_webhook_endpoints, "octet_length(name) BETWEEN 1 AND 100", name: "outbound_webhooks_name"
    add_check_constraint :outbound_webhook_endpoints, "credential_key ~ '^[a-z][a-z0-9_]{0,63}$'", name: "outbound_webhooks_credential"
    add_check_constraint :outbound_webhook_endpoints, "jsonb_typeof(categories) = 'array' AND jsonb_array_length(categories) BETWEEN 1 AND 6",
      name: "outbound_webhooks_categories"

    create_table :outbound_webhook_deliveries do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :outbound_webhook_endpoint, null: false, foreign_key: true
      t.references :notification, null: false, foreign_key: true
      t.string :event_key, null: false
      t.text :target_url, null: false
      t.string :credential_key, null: false
      t.text :payload, null: false
      t.string :payload_sha256, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempt_count, null: false, default: 0
      t.string :failure_code
      t.datetime :last_attempted_at
      t.datetime :delivered_at
      t.timestamps
    end
    add_index :outbound_webhook_deliveries, [ :outbound_webhook_endpoint_id, :notification_id ],
      unique: true, name: "index_outbound_webhooks_on_endpoint_and_notification"
    add_index :outbound_webhook_deliveries, :event_key, unique: true
    add_check_constraint :outbound_webhook_deliveries, "event_key ~ '^[0-9a-f-]{36}$'", name: "outbound_webhook_deliveries_key"
    add_check_constraint :outbound_webhook_deliveries, "payload_sha256 ~ '^[0-9a-f]{64}$'", name: "outbound_webhook_deliveries_digest"
    add_check_constraint :outbound_webhook_deliveries, "status IN ('pending', 'sending', 'delivered', 'failed') AND attempt_count BETWEEN 0 AND 5",
      name: "outbound_webhook_deliveries_state"

    add_foreign_key :outbound_webhook_deliveries, :outbound_webhook_endpoints,
      column: [ :workspace_id, :outbound_webhook_endpoint_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_outbound_webhook_delivery_endpoint"
    add_foreign_key :outbound_webhook_deliveries, :notifications,
      column: [ :workspace_id, :notification_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_outbound_webhook_delivery_notification"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_outbound_webhook_delivery()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'UPDATE' AND
               ROW(OLD.id, OLD.workspace_id, OLD.outbound_webhook_endpoint_id, OLD.notification_id,
                   OLD.event_key, OLD.target_url, OLD.credential_key, OLD.payload, OLD.payload_sha256, OLD.created_at)
               IS NOT DISTINCT FROM
               ROW(NEW.id, NEW.workspace_id, NEW.outbound_webhook_endpoint_id, NEW.notification_id,
                   NEW.event_key, NEW.target_url, NEW.credential_key, NEW.payload, NEW.payload_sha256, NEW.created_at) AND
               ((OLD.status = 'pending' AND NEW.status IN ('sending', 'failed')) OR
                (OLD.status = 'sending' AND NEW.status IN ('delivered', 'failed')) OR
                (OLD.status = 'failed' AND NEW.status IN ('sending', 'failed'))) THEN
              RETURN NEW;
            END IF;
            RAISE EXCEPTION 'outbound webhook delivery snapshots are immutable';
          END;
          $$;
          CREATE TRIGGER outbound_webhook_deliveries_protect
          BEFORE UPDATE OR DELETE ON outbound_webhook_deliveries
          FOR EACH ROW EXECUTE FUNCTION protect_outbound_webhook_delivery();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER outbound_webhook_deliveries_protect ON outbound_webhook_deliveries"
        execute "DROP FUNCTION protect_outbound_webhook_delivery()"
      end
    end
  end
end
