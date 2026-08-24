class CreateHumanEmailSendRecords < ActiveRecord::Migration[8.1]
  def up
    add_index :memberships, [ :workspace_id, :id, :user_id ], unique: true,
      name: "index_memberships_on_workspace_id_id_user_id"
    add_index :support_cases, [ :workspace_id, :id, :conversation_id ], unique: true,
      name: "index_support_cases_on_tenant_conversation"
    add_index :email_threads, [ :workspace_id, :id, :conversation_id ], unique: true,
      name: "index_email_threads_on_workspace_thread_conversation"
    add_column :email_message_links, :reply_to_address, :string
    add_check_constraint :email_message_links,
      "reply_to_address IS NULL OR (length(reply_to_address) <= 254 AND reply_to_address ~ '^[^[:space:]<>@]+@[^[:space:]<>@]+$')",
      name: "email_message_links_reply_to_address"

    create_table :email_drafts do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :support_case_id, null: false
      t.bigint :email_thread_id, null: false
      t.bigint :conversation_id, null: false
      t.bigint :updated_by_id, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "ready"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :email_drafts, [ :workspace_id, :id ], unique: true
    add_index :email_drafts, [ :workspace_id, :id, :email_thread_id, :conversation_id ], unique: true,
      name: "index_email_drafts_on_tenant_thread"
    add_index :email_drafts, [ :workspace_id, :support_case_id ], unique: true
    add_foreign_key :email_drafts, :support_cases,
      column: [ :workspace_id, :support_case_id, :conversation_id ],
      primary_key: [ :workspace_id, :id, :conversation_id ]
    add_foreign_key :email_drafts, :email_threads,
      column: [ :workspace_id, :email_thread_id, :conversation_id ],
      primary_key: [ :workspace_id, :id, :conversation_id ]
    add_foreign_key :email_drafts, :users, column: :updated_by_id
    add_foreign_key :email_drafts, :memberships,
      column: [ :workspace_id, :updated_by_id ], primary_key: [ :workspace_id, :user_id ]
    add_check_constraint :email_drafts, "status IN ('ready', 'sending', 'sent')", name: "email_drafts_status"
    add_check_constraint :email_drafts, "octet_length(body) <= 1048576", name: "email_drafts_body_size"

    create_table :outbound_email_deliveries do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :email_draft_id, null: false
      t.bigint :shared_email_inbox_id, null: false
      t.bigint :email_thread_id, null: false
      t.bigint :conversation_id, null: false
      t.bigint :conversation_message_id
      t.bigint :actor_membership_id, null: false
      t.bigint :actor_user_id, null: false
      t.string :idempotency_key, null: false
      t.string :message_id, null: false
      t.string :in_reply_to_message_id
      t.string :from_address, null: false
      t.string :to_address, null: false
      t.string :subject, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "sending"
      t.string :failure_code
      t.datetime :started_at, null: false
      t.datetime :sent_at
      t.timestamps
    end
    add_index :outbound_email_deliveries, [ :workspace_id, :id ], unique: true
    add_index :outbound_email_deliveries, [ :workspace_id, :idempotency_key ], unique: true, name: "index_outbound_email_deliveries_on_idempotency"
    add_index :outbound_email_deliveries, [ :shared_email_inbox_id, :message_id ], unique: true
    add_foreign_key :outbound_email_deliveries, :email_drafts,
      column: [ :workspace_id, :email_draft_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :outbound_email_deliveries, :email_drafts,
      column: [ :workspace_id, :email_draft_id, :email_thread_id, :conversation_id ],
      primary_key: [ :workspace_id, :id, :email_thread_id, :conversation_id ]
    add_foreign_key :outbound_email_deliveries, :shared_email_inboxes,
      column: [ :workspace_id, :shared_email_inbox_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :outbound_email_deliveries, :email_threads,
      column: [ :workspace_id, :shared_email_inbox_id, :email_thread_id, :conversation_id ],
      primary_key: [ :workspace_id, :shared_email_inbox_id, :id, :conversation_id ]
    add_foreign_key :outbound_email_deliveries, :conversation_messages,
      column: [ :workspace_id, :conversation_id, :conversation_message_id ],
      primary_key: [ :workspace_id, :conversation_id, :id ]
    add_foreign_key :outbound_email_deliveries, :memberships,
      column: [ :workspace_id, :actor_membership_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :outbound_email_deliveries, :memberships,
      column: [ :workspace_id, :actor_membership_id, :actor_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :outbound_email_deliveries, :users, column: :actor_user_id
    add_check_constraint :outbound_email_deliveries,
      "status IN ('sending', 'sent', 'failed', 'unknown')", name: "outbound_email_deliveries_status"
    add_check_constraint :outbound_email_deliveries,
      "octet_length(body) <= 1048576", name: "outbound_email_deliveries_body_size"
    add_check_constraint :outbound_email_deliveries,
      "(status = 'sent' AND conversation_message_id IS NOT NULL AND sent_at IS NOT NULL AND failure_code IS NULL) OR " \
      "(status IN ('sending', 'failed', 'unknown') AND conversation_message_id IS NULL AND sent_at IS NULL AND " \
      "((status = 'sending' AND failure_code IS NULL) OR (status IN ('failed', 'unknown') AND failure_code IS NOT NULL)))",
      name: "outbound_email_deliveries_state"

    protect_delivery_records
  end

  def down
    drop_table :outbound_email_deliveries
    drop_table :email_drafts
    remove_check_constraint :email_message_links, name: "email_message_links_reply_to_address"
    remove_column :email_message_links, :reply_to_address
    remove_index :email_threads, name: "index_email_threads_on_workspace_thread_conversation"
    remove_index :support_cases, name: "index_support_cases_on_tenant_conversation"
    remove_index :memberships, name: "index_memberships_on_workspace_id_id_user_id"
    execute "DROP FUNCTION IF EXISTS protect_outbound_email_delivery()"
  end

  private
    def protect_delivery_records
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION protect_outbound_email_delivery()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              IF TG_OP = 'UPDATE' AND
                 ROW(OLD.id, OLD.workspace_id, OLD.email_draft_id, OLD.shared_email_inbox_id,
                     OLD.email_thread_id, OLD.conversation_id, OLD.actor_membership_id,
                     OLD.actor_user_id, OLD.idempotency_key, OLD.message_id,
                     OLD.in_reply_to_message_id, OLD.from_address, OLD.to_address,
                     OLD.subject, OLD.body, OLD.started_at, OLD.created_at)
                 IS NOT DISTINCT FROM
                 ROW(NEW.id, NEW.workspace_id, NEW.email_draft_id, NEW.shared_email_inbox_id,
                     NEW.email_thread_id, NEW.conversation_id, NEW.actor_membership_id,
                     NEW.actor_user_id, NEW.idempotency_key, NEW.message_id,
                     NEW.in_reply_to_message_id, NEW.from_address, NEW.to_address,
                     NEW.subject, NEW.body, NEW.started_at, NEW.created_at) AND
                 ((OLD.status = 'sending' AND NEW.status IN ('sent', 'failed', 'unknown')) OR
                  (OLD.status = 'unknown' AND NEW.status IN ('sent', 'failed'))) THEN
                RETURN NEW;
              END IF;
              RAISE EXCEPTION 'outbound email delivery records are durable';
            END;
            $$;

            CREATE TRIGGER outbound_email_deliveries_protect_record
            BEFORE UPDATE OR DELETE ON outbound_email_deliveries
            FOR EACH ROW EXECUTE FUNCTION protect_outbound_email_delivery();
            CREATE TRIGGER outbound_email_deliveries_no_truncate
            BEFORE TRUNCATE ON outbound_email_deliveries
            FOR EACH STATEMENT EXECUTE FUNCTION protect_outbound_email_delivery();
          SQL
        end

        direction.down do
          execute "DROP TRIGGER IF EXISTS outbound_email_deliveries_no_truncate ON outbound_email_deliveries"
          execute "DROP TRIGGER IF EXISTS outbound_email_deliveries_protect_record ON outbound_email_deliveries"
          execute "DROP FUNCTION IF EXISTS protect_outbound_email_delivery()"
        end
      end
    end
end
