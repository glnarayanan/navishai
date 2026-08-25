class CreateSharedEmailIntakeRecords < ActiveRecord::Migration[8.1]
  def change
    create_inboxes
    create_threads
    create_deliveries
    create_message_links
    make_sources_durable
  end

  private
    def create_inboxes
      create_table :shared_email_inboxes do |t|
        t.references :workspace, null: false, foreign_key: true
        t.string :name, null: false
        t.string :email_address, null: false
        t.string :webhook_key, null: false
        t.string :credential_key, null: false
        t.boolean :active, null: false, default: true
        t.timestamps
      end
      add_index :shared_email_inboxes, [ :workspace_id, :id ], unique: true
      add_index :shared_email_inboxes, [ :workspace_id, :email_address ], unique: true
      add_index :shared_email_inboxes, :webhook_key, unique: true
    end

    def create_threads
      create_table :email_threads do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :shared_email_inbox_id, null: false
        t.bigint :conversation_id, null: false
        t.string :thread_key, null: false
        t.timestamps
      end
      add_index :email_threads, [ :workspace_id, :id ], unique: true
      add_index :email_threads, [ :workspace_id, :shared_email_inbox_id, :id, :conversation_id ], unique: true, name: "index_email_threads_on_tenant_conversation"
      add_index :email_threads, [ :shared_email_inbox_id, :thread_key ], unique: true
      add_foreign_key :email_threads, :shared_email_inboxes,
        column: [ :workspace_id, :shared_email_inbox_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :email_threads, :conversations,
        column: [ :workspace_id, :conversation_id ],
        primary_key: [ :workspace_id, :id ]
    end

    def create_deliveries
      create_table :inbound_email_deliveries do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :shared_email_inbox_id, null: false
        t.string :source_message_id, null: false
        t.string :content_sha256, null: false
        t.binary :raw_email, null: false
        t.string :status, null: false, default: "received"
        t.string :failure_code
        t.bigint :conversation_id
        t.bigint :conversation_message_id
        t.datetime :received_at, null: false
        t.datetime :processed_at
        t.integer :attempt_count, null: false, default: 0
        t.datetime :last_attempted_at
        t.timestamps
      end
      add_index :inbound_email_deliveries, [ :workspace_id, :id ], unique: true
      add_index :inbound_email_deliveries, [ :shared_email_inbox_id, :source_message_id, :content_sha256 ],
        unique: true, name: "index_inbound_email_deliveries_on_source"
      add_index :inbound_email_deliveries, [ :workspace_id, :status, :received_at ], name: "index_inbound_email_deliveries_on_visibility"
      add_foreign_key :inbound_email_deliveries, :shared_email_inboxes,
        column: [ :workspace_id, :shared_email_inbox_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :inbound_email_deliveries, :conversations,
        column: [ :workspace_id, :conversation_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :inbound_email_deliveries, :conversation_messages,
        column: [ :workspace_id, :conversation_id, :conversation_message_id ],
        primary_key: [ :workspace_id, :conversation_id, :id ]
      add_check_constraint :inbound_email_deliveries,
        "octet_length(raw_email) <= 10485760",
        name: "inbound_email_deliveries_size"
      add_check_constraint :inbound_email_deliveries,
        "content_sha256 ~ '^[0-9a-f]{64}$'",
        name: "inbound_email_deliveries_digest"
      add_check_constraint :inbound_email_deliveries,
        "(attempt_count = 0 AND last_attempted_at IS NULL) OR (attempt_count > 0 AND last_attempted_at IS NOT NULL)",
        name: "inbound_email_deliveries_attempts"
      add_check_constraint :inbound_email_deliveries,
        "status IN ('received', 'processed', 'failed')",
        name: "inbound_email_deliveries_status"
      add_check_constraint :inbound_email_deliveries,
        "failure_code IS NULL OR failure_code IN ('parse_error', 'missing_sender', 'missing_message_id', 'message_id_conflict', 'empty_body', 'body_too_large', 'identity_ambiguous', 'identity_error', 'persistence_error')",
        name: "inbound_email_deliveries_failure_code"
      add_check_constraint :inbound_email_deliveries,
        "(status = 'received' AND failure_code IS NULL AND conversation_id IS NULL AND conversation_message_id IS NULL AND processed_at IS NULL) OR " \
        "(status = 'processed' AND failure_code IS NULL AND conversation_id IS NOT NULL AND conversation_message_id IS NOT NULL AND processed_at IS NOT NULL) OR " \
        "(status = 'failed' AND failure_code IS NOT NULL AND conversation_id IS NULL AND conversation_message_id IS NULL AND processed_at IS NOT NULL)",
        name: "inbound_email_deliveries_state"
    end

    def create_message_links
      create_table :email_message_links do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :shared_email_inbox_id, null: false
        t.bigint :email_thread_id, null: false
        t.bigint :conversation_id, null: false
        t.bigint :conversation_message_id, null: false
        t.string :message_id, null: false
        t.timestamps
      end
      add_index :email_message_links, [ :workspace_id, :id ], unique: true
      add_index :email_message_links, [ :shared_email_inbox_id, :message_id ], unique: true
      add_foreign_key :email_message_links, :shared_email_inboxes,
        column: [ :workspace_id, :shared_email_inbox_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :email_message_links, :email_threads,
        column: [ :workspace_id, :shared_email_inbox_id, :email_thread_id, :conversation_id ],
        primary_key: [ :workspace_id, :shared_email_inbox_id, :id, :conversation_id ]
      add_foreign_key :email_message_links, :conversation_messages,
        column: [ :workspace_id, :conversation_id, :conversation_message_id ],
        primary_key: [ :workspace_id, :conversation_id, :id ]
    end

    def make_sources_durable
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION prevent_inbound_email_source_mutation()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              IF TG_OP = 'UPDATE' AND
                 OLD.workspace_id IS NOT DISTINCT FROM NEW.workspace_id AND
                 OLD.shared_email_inbox_id IS NOT DISTINCT FROM NEW.shared_email_inbox_id AND
                 OLD.source_message_id IS NOT DISTINCT FROM NEW.source_message_id AND
                 OLD.content_sha256 IS NOT DISTINCT FROM NEW.content_sha256 AND
                 OLD.raw_email IS NOT DISTINCT FROM NEW.raw_email AND
                 OLD.received_at IS NOT DISTINCT FROM NEW.received_at AND
                 OLD.created_at IS NOT DISTINCT FROM NEW.created_at AND
                 ((OLD.status = 'received' AND NEW.status IN ('received', 'processed', 'failed')) OR
                  (OLD.status = 'failed' AND NEW.status IN ('received', 'failed'))) THEN
                RETURN NEW;
              END IF;
              RAISE EXCEPTION 'inbound email source records are durable';
            END;
            $$;

            CREATE TRIGGER inbound_email_deliveries_protect_source
            BEFORE UPDATE OR DELETE ON inbound_email_deliveries
            FOR EACH ROW EXECUTE FUNCTION prevent_inbound_email_source_mutation();
            CREATE TRIGGER inbound_email_deliveries_no_truncate
            BEFORE TRUNCATE ON inbound_email_deliveries
            FOR EACH STATEMENT EXECUTE FUNCTION prevent_inbound_email_source_mutation();

            CREATE TRIGGER email_threads_append_only
            BEFORE UPDATE OR DELETE ON email_threads
            FOR EACH ROW EXECUTE FUNCTION prevent_helpdesk_record_mutation();
            CREATE TRIGGER email_threads_no_truncate
            BEFORE TRUNCATE ON email_threads
            FOR EACH STATEMENT EXECUTE FUNCTION prevent_helpdesk_record_mutation();

            CREATE TRIGGER email_message_links_append_only
            BEFORE UPDATE OR DELETE ON email_message_links
            FOR EACH ROW EXECUTE FUNCTION prevent_helpdesk_record_mutation();
            CREATE TRIGGER email_message_links_no_truncate
            BEFORE TRUNCATE ON email_message_links
            FOR EACH STATEMENT EXECUTE FUNCTION prevent_helpdesk_record_mutation();
          SQL
        end

        direction.down do
          execute "DROP TRIGGER IF EXISTS email_message_links_no_truncate ON email_message_links"
          execute "DROP TRIGGER IF EXISTS email_message_links_append_only ON email_message_links"
          execute "DROP TRIGGER IF EXISTS email_threads_no_truncate ON email_threads"
          execute "DROP TRIGGER IF EXISTS email_threads_append_only ON email_threads"
          execute "DROP TRIGGER IF EXISTS inbound_email_deliveries_no_truncate ON inbound_email_deliveries"
          execute "DROP TRIGGER IF EXISTS inbound_email_deliveries_protect_source ON inbound_email_deliveries"
          execute "DROP FUNCTION IF EXISTS prevent_inbound_email_source_mutation()"
        end
      end
    end
end
