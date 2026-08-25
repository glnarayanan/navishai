class CreateIntercomHumanSendRecords < ActiveRecord::Migration[8.1]
  def change
    add_index :intercom_conversation_links, [ :workspace_id, :id, :conversation_id ], unique: true,
      name: "index_intercom_conversations_on_tenant_conversation_id"

    create_table :intercom_drafts do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :support_case_id, null: false
      t.bigint :intercom_conversation_link_id, null: false
      t.bigint :conversation_id, null: false
      t.bigint :updated_by_id, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "ready"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :intercom_drafts, [ :workspace_id, :id ], unique: true
    add_index :intercom_drafts, [ :workspace_id, :support_case_id ], unique: true
    add_index :intercom_drafts, [ :workspace_id, :id, :intercom_conversation_link_id, :conversation_id ],
      unique: true, name: "index_intercom_drafts_on_tenant_link"
    add_foreign_key :intercom_drafts, :support_cases,
      column: [ :workspace_id, :support_case_id, :conversation_id ],
      primary_key: [ :workspace_id, :id, :conversation_id ]
    add_foreign_key :intercom_drafts, :intercom_conversation_links,
      column: [ :workspace_id, :intercom_conversation_link_id, :conversation_id ],
      primary_key: [ :workspace_id, :id, :conversation_id ]
    add_foreign_key :intercom_drafts, :memberships,
      column: [ :workspace_id, :updated_by_id ], primary_key: [ :workspace_id, :user_id ]
    add_check_constraint :intercom_drafts, "status IN ('ready', 'sending', 'sent')", name: "intercom_drafts_status"
    add_check_constraint :intercom_drafts, "octet_length(body) <= 1048576", name: "intercom_drafts_body_size"

    create_table :intercom_outbound_deliveries do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :intercom_draft_id, null: false
      t.bigint :intercom_connection_id, null: false
      t.bigint :intercom_conversation_link_id, null: false
      t.bigint :conversation_id, null: false
      t.bigint :conversation_message_id
      t.bigint :actor_membership_id, null: false
      t.bigint :actor_user_id, null: false
      t.string :idempotency_key, null: false
      t.string :remote_conversation_id, null: false
      t.string :source_part_id, null: false
      t.string :remote_part_id
      t.string :admin_id, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "sending"
      t.string :failure_code
      t.datetime :started_at, null: false
      t.datetime :sent_at
      t.timestamps
    end
    add_index :intercom_outbound_deliveries, [ :workspace_id, :id ], unique: true
    add_index :intercom_outbound_deliveries, [ :workspace_id, :idempotency_key ], unique: true,
      name: "index_intercom_outbound_on_idempotency"
    add_index :intercom_outbound_deliveries, [ :intercom_connection_id, :remote_part_id ], unique: true,
      where: "remote_part_id IS NOT NULL", name: "index_intercom_outbound_on_remote_part"
    add_foreign_key :intercom_outbound_deliveries, :intercom_drafts,
      column: [ :workspace_id, :intercom_draft_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :intercom_outbound_deliveries, :intercom_drafts,
      column: [ :workspace_id, :intercom_draft_id, :intercom_conversation_link_id, :conversation_id ],
      primary_key: [ :workspace_id, :id, :intercom_conversation_link_id, :conversation_id ]
    add_foreign_key :intercom_outbound_deliveries, :intercom_connections,
      column: [ :workspace_id, :intercom_connection_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :intercom_outbound_deliveries, :intercom_conversation_links,
      column: [ :workspace_id, :intercom_connection_id, :intercom_conversation_link_id, :conversation_id ],
      primary_key: [ :workspace_id, :intercom_connection_id, :id, :conversation_id ]
    add_foreign_key :intercom_outbound_deliveries, :conversation_messages,
      column: [ :workspace_id, :conversation_id, :conversation_message_id ],
      primary_key: [ :workspace_id, :conversation_id, :id ]
    add_foreign_key :intercom_outbound_deliveries, :memberships,
      column: [ :workspace_id, :actor_membership_id, :actor_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ]
    add_check_constraint :intercom_outbound_deliveries,
      "status IN ('sending', 'sent', 'failed', 'unknown')", name: "intercom_outbound_deliveries_status"
    add_check_constraint :intercom_outbound_deliveries,
      "octet_length(body) <= 1048576", name: "intercom_outbound_deliveries_body_size"
    add_check_constraint :intercom_outbound_deliveries,
      "failure_code IS NULL OR failure_code IN ('configuration_error', 'remote_rejected', 'unknown_outcome', 'confirmed_not_sent')",
      name: "intercom_outbound_deliveries_failure"
    add_check_constraint :intercom_outbound_deliveries,
      "(status = 'sent' AND conversation_message_id IS NOT NULL AND remote_part_id IS NOT NULL AND sent_at IS NOT NULL AND failure_code IS NULL) OR " \
      "(status IN ('sending', 'failed', 'unknown') AND conversation_message_id IS NULL AND remote_part_id IS NULL AND sent_at IS NULL AND " \
      "((status = 'sending' AND failure_code IS NULL) OR (status IN ('failed', 'unknown') AND failure_code IS NOT NULL)))",
      name: "intercom_outbound_deliveries_state"

    protect_deliveries
  end

  private
    def protect_deliveries
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION protect_intercom_outbound_delivery()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              IF TG_OP = 'UPDATE' AND
                 ROW(OLD.id, OLD.workspace_id, OLD.intercom_draft_id, OLD.intercom_connection_id,
                     OLD.intercom_conversation_link_id, OLD.conversation_id, OLD.actor_membership_id,
                     OLD.actor_user_id, OLD.idempotency_key, OLD.remote_conversation_id,
                     OLD.source_part_id, OLD.admin_id, OLD.body, OLD.started_at, OLD.created_at)
                 IS NOT DISTINCT FROM
                 ROW(NEW.id, NEW.workspace_id, NEW.intercom_draft_id, NEW.intercom_connection_id,
                     NEW.intercom_conversation_link_id, NEW.conversation_id, NEW.actor_membership_id,
                     NEW.actor_user_id, NEW.idempotency_key, NEW.remote_conversation_id,
                     NEW.source_part_id, NEW.admin_id, NEW.body, NEW.started_at, NEW.created_at) AND
                 ((OLD.status = 'sending' AND NEW.status IN ('sent', 'failed', 'unknown')) OR
                  (OLD.status = 'unknown' AND NEW.status IN ('sent', 'failed'))) THEN
                RETURN NEW;
              END IF;
              RAISE EXCEPTION 'Intercom outbound delivery records are durable';
            END;
            $$;

            CREATE TRIGGER intercom_outbound_deliveries_protect_record
            BEFORE UPDATE OR DELETE ON intercom_outbound_deliveries
            FOR EACH ROW EXECUTE FUNCTION protect_intercom_outbound_delivery();
            CREATE TRIGGER intercom_outbound_deliveries_no_truncate
            BEFORE TRUNCATE ON intercom_outbound_deliveries
            FOR EACH STATEMENT EXECUTE FUNCTION protect_intercom_outbound_delivery();
          SQL
        end
        direction.down do
          execute "DROP TRIGGER IF EXISTS intercom_outbound_deliveries_no_truncate ON intercom_outbound_deliveries"
          execute "DROP TRIGGER IF EXISTS intercom_outbound_deliveries_protect_record ON intercom_outbound_deliveries"
          execute "DROP FUNCTION IF EXISTS protect_intercom_outbound_delivery()"
        end
      end
    end
end
