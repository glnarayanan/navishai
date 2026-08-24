class CreateIntercomSyncRecords < ActiveRecord::Migration[8.1]
  def change
    create_connections
    add_tagging_source_ownership
    create_conversation_links
    create_part_links
    create_tag_links
    create_webhook_deliveries
    create_sync_operations
    protect_source_records
  end

  private
    def create_connections
      create_table :intercom_connections do |t|
        t.references :workspace, null: false, foreign_key: true
        t.string :name, null: false
        t.string :remote_workspace_id, null: false
        t.string :credential_key, null: false
        t.string :webhook_key, null: false
        t.boolean :active, null: false, default: true
        t.string :reconciliation_cursor
        t.datetime :last_reconciled_at
        t.string :last_error_code
        t.timestamps
      end
      add_index :intercom_connections, [ :workspace_id, :id ], unique: true
      add_index :intercom_connections, [ :workspace_id, :remote_workspace_id ], unique: true
      add_index :intercom_connections, :webhook_key, unique: true
    end

    def add_tagging_source_ownership
      add_column :support_case_taggings, :source_intercom_connection_id, :bigint
      add_index :support_case_taggings, [ :workspace_id, :source_intercom_connection_id ],
        name: "index_case_taggings_on_intercom_source"
      add_foreign_key :support_case_taggings, :intercom_connections,
        column: [ :workspace_id, :source_intercom_connection_id ], primary_key: [ :workspace_id, :id ]
    end

    def create_conversation_links
      create_table :intercom_conversation_links do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :intercom_connection_id, null: false
        t.bigint :conversation_id, null: false
        t.bigint :support_case_id, null: false
        t.string :remote_conversation_id, null: false
        t.string :remote_state, null: false
        t.string :remote_assignee_id
        t.string :remote_assignee_name
        t.string :source_digest, null: false
        t.datetime :remote_updated_at, null: false
        t.datetime :synced_at, null: false
        t.timestamps
      end
      add_index :intercom_conversation_links, [ :workspace_id, :id ], unique: true
      add_index :intercom_conversation_links, [ :workspace_id, :conversation_id ], unique: true
      add_index :intercom_conversation_links, [ :workspace_id, :intercom_connection_id, :id ], unique: true,
        name: "index_intercom_conversations_on_tenant_id"
      add_index :intercom_conversation_links, [ :intercom_connection_id, :remote_conversation_id ], unique: true,
        name: "index_intercom_conversations_on_remote_id"
      add_index :intercom_conversation_links, [ :workspace_id, :intercom_connection_id, :id, :conversation_id ],
        unique: true, name: "index_intercom_conversations_on_tenant_conversation"
      add_index :intercom_conversation_links, [ :workspace_id, :intercom_connection_id, :id, :conversation_id, :support_case_id ],
        unique: true, name: "index_intercom_conversations_on_tenant_chain"
      add_foreign_key :intercom_conversation_links, :intercom_connections,
        column: [ :workspace_id, :intercom_connection_id ], primary_key: [ :workspace_id, :id ]
      add_foreign_key :intercom_conversation_links, :conversations,
        column: [ :workspace_id, :conversation_id ], primary_key: [ :workspace_id, :id ]
      add_foreign_key :intercom_conversation_links, :support_cases,
        column: [ :workspace_id, :conversation_id, :support_case_id ], primary_key: [ :workspace_id, :conversation_id, :id ]
      add_check_constraint :intercom_conversation_links, "source_digest ~ '^[0-9a-f]{64}$'",
        name: "intercom_conversation_links_digest"
    end

    def create_part_links
      create_table :intercom_part_links do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :intercom_connection_id, null: false
        t.bigint :intercom_conversation_link_id, null: false
        t.bigint :conversation_id, null: false
        t.bigint :conversation_message_id
        t.string :remote_part_id, null: false
        t.string :part_type, null: false
        t.string :author_name
        t.text :body, null: false
        t.string :source_digest, null: false
        t.datetime :remote_created_at, null: false
        t.datetime :redacted_at
        t.timestamps
      end
      add_index :intercom_part_links, [ :workspace_id, :id ], unique: true
      add_index :intercom_part_links, [ :intercom_connection_id, :remote_part_id ], unique: true
      add_index :intercom_part_links, [ :workspace_id, :conversation_id, :conversation_message_id ], unique: true,
        where: "conversation_message_id IS NOT NULL", name: "index_intercom_parts_on_conversation_message"
      add_foreign_key :intercom_part_links, :intercom_connections,
        column: [ :workspace_id, :intercom_connection_id ], primary_key: [ :workspace_id, :id ]
      add_foreign_key :intercom_part_links, :intercom_conversation_links,
        column: [ :workspace_id, :intercom_connection_id, :intercom_conversation_link_id, :conversation_id ],
        primary_key: [ :workspace_id, :intercom_connection_id, :id, :conversation_id ]
      add_foreign_key :intercom_part_links, :conversation_messages,
        column: [ :workspace_id, :conversation_id, :conversation_message_id ],
        primary_key: [ :workspace_id, :conversation_id, :id ]
      add_check_constraint :intercom_part_links, "part_type IN ('contact_reply', 'admin_reply', 'note')",
        name: "intercom_part_links_type"
      add_check_constraint :intercom_part_links, "source_digest ~ '^[0-9a-f]{64}$'",
        name: "intercom_part_links_digest"
      add_check_constraint :intercom_part_links,
        "(part_type = 'note' AND conversation_message_id IS NULL) OR (part_type <> 'note' AND conversation_message_id IS NOT NULL)",
        name: "intercom_part_links_message"
    end

    def create_tag_links
      create_table :intercom_tag_links do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :intercom_connection_id, null: false
        t.bigint :tag_id, null: false
        t.string :remote_tag_id, null: false
        t.timestamps
      end
      add_index :intercom_tag_links, [ :workspace_id, :id ], unique: true
      add_index :intercom_tag_links, [ :intercom_connection_id, :remote_tag_id ], unique: true
      add_index :intercom_tag_links, [ :intercom_connection_id, :tag_id ], unique: true
      add_foreign_key :intercom_tag_links, :intercom_connections,
        column: [ :workspace_id, :intercom_connection_id ], primary_key: [ :workspace_id, :id ]
      add_foreign_key :intercom_tag_links, :tags,
        column: [ :workspace_id, :tag_id ], primary_key: [ :workspace_id, :id ]
    end

    def create_webhook_deliveries
      create_table :intercom_webhook_deliveries do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :intercom_connection_id, null: false
        t.string :notification_id, null: false
        t.string :topic, null: false
        t.string :content_sha256, null: false
        t.binary :raw_payload, null: false
        t.string :status, null: false, default: "received"
        t.string :failure_code
        t.integer :attempt_count, null: false, default: 0
        t.datetime :received_at, null: false
        t.datetime :last_attempted_at
        t.datetime :processed_at
        t.timestamps
      end
      add_index :intercom_webhook_deliveries, [ :workspace_id, :id ], unique: true
      add_index :intercom_webhook_deliveries, [ :intercom_connection_id, :notification_id ], unique: true,
        name: "index_intercom_webhooks_on_notification"
      add_index :intercom_webhook_deliveries, [ :workspace_id, :status, :received_at ],
        name: "index_intercom_webhooks_on_visibility"
      add_foreign_key :intercom_webhook_deliveries, :intercom_connections,
        column: [ :workspace_id, :intercom_connection_id ], primary_key: [ :workspace_id, :id ]
      add_check_constraint :intercom_webhook_deliveries, "octet_length(raw_payload) <= 1048576",
        name: "intercom_webhook_deliveries_size"
      add_check_constraint :intercom_webhook_deliveries, "content_sha256 ~ '^[0-9a-f]{64}$'",
        name: "intercom_webhook_deliveries_digest"
      add_check_constraint :intercom_webhook_deliveries, "status IN ('received', 'processed', 'failed')",
        name: "intercom_webhook_deliveries_status"
      add_check_constraint :intercom_webhook_deliveries,
        "(attempt_count = 0 AND last_attempted_at IS NULL) OR (attempt_count > 0 AND last_attempted_at IS NOT NULL)",
        name: "intercom_webhook_deliveries_attempts"
      add_check_constraint :intercom_webhook_deliveries,
        "failure_code IS NULL OR failure_code IN ('invalid_payload', 'unsupported_topic', 'identity_ambiguous', 'remote_unavailable', 'persistence_error')",
        name: "intercom_webhook_deliveries_failure_code"
      add_check_constraint :intercom_webhook_deliveries,
        "(status = 'received' AND failure_code IS NULL AND processed_at IS NULL) OR " \
        "(status = 'processed' AND failure_code IS NULL AND processed_at IS NOT NULL) OR " \
        "(status = 'failed' AND failure_code IS NOT NULL AND processed_at IS NOT NULL)",
        name: "intercom_webhook_deliveries_state"
    end

    def create_sync_operations
      create_table :intercom_sync_operations do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :intercom_connection_id, null: false
        t.bigint :intercom_conversation_link_id, null: false
        t.bigint :membership_id, null: false
        t.bigint :user_id, null: false
        t.string :operation_key, null: false
        t.string :operation_kind, null: false
        t.jsonb :payload, null: false, default: {}
        t.string :status, null: false, default: "pending"
        t.string :failure_code
        t.string :remote_object_id
        t.integer :attempt_count, null: false, default: 0
        t.datetime :last_attempted_at
        t.datetime :completed_at
        t.timestamps
      end
      add_index :intercom_sync_operations, [ :workspace_id, :id ], unique: true
      add_index :intercom_sync_operations, :operation_key, unique: true
      add_index :intercom_sync_operations, [ :workspace_id, :status, :created_at ]
      add_foreign_key :intercom_sync_operations, :intercom_connections,
        column: [ :workspace_id, :intercom_connection_id ], primary_key: [ :workspace_id, :id ]
      add_foreign_key :intercom_sync_operations, :intercom_conversation_links,
        column: [ :workspace_id, :intercom_connection_id, :intercom_conversation_link_id ],
        primary_key: [ :workspace_id, :intercom_connection_id, :id ]
      add_foreign_key :intercom_sync_operations, :memberships,
        column: [ :workspace_id, :membership_id, :user_id ],
        primary_key: [ :workspace_id, :id, :user_id ]
      add_check_constraint :intercom_sync_operations, "operation_kind IN ('note', 'assign', 'tag', 'untag')",
        name: "intercom_sync_operations_kind"
      add_check_constraint :intercom_sync_operations, "status IN ('pending', 'sending', 'completed', 'failed', 'unknown')",
        name: "intercom_sync_operations_status"
      add_check_constraint :intercom_sync_operations,
        "failure_code IS NULL OR failure_code IN ('configuration_error', 'remote_rejected', 'outcome_unknown')",
        name: "intercom_sync_operations_failure"
      add_check_constraint :intercom_sync_operations, "octet_length(payload::text) <= 65536",
        name: "intercom_sync_operations_payload"
      add_check_constraint :intercom_sync_operations,
        "(status = 'pending' AND attempt_count = 0 AND last_attempted_at IS NULL AND failure_code IS NULL AND completed_at IS NULL) OR " \
        "(status = 'sending' AND attempt_count > 0 AND last_attempted_at IS NOT NULL AND failure_code IS NULL AND completed_at IS NULL) OR " \
        "(status = 'completed' AND attempt_count > 0 AND last_attempted_at IS NOT NULL AND failure_code IS NULL AND completed_at IS NOT NULL) OR " \
        "(status IN ('failed', 'unknown') AND attempt_count > 0 AND last_attempted_at IS NOT NULL AND failure_code IS NOT NULL AND completed_at IS NULL)",
        name: "intercom_sync_operations_state"
    end

    def protect_source_records
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION prevent_intercom_webhook_source_mutation()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              IF TG_OP = 'UPDATE' AND
                 OLD.id IS NOT DISTINCT FROM NEW.id AND
                 OLD.workspace_id IS NOT DISTINCT FROM NEW.workspace_id AND
                 OLD.intercom_connection_id IS NOT DISTINCT FROM NEW.intercom_connection_id AND
                 OLD.notification_id IS NOT DISTINCT FROM NEW.notification_id AND
                 OLD.topic IS NOT DISTINCT FROM NEW.topic AND
                 OLD.content_sha256 IS NOT DISTINCT FROM NEW.content_sha256 AND
                 OLD.raw_payload IS NOT DISTINCT FROM NEW.raw_payload AND
                 OLD.received_at IS NOT DISTINCT FROM NEW.received_at AND
                 OLD.created_at IS NOT DISTINCT FROM NEW.created_at AND
                 ((OLD.status = 'received' AND NEW.status IN ('received', 'processed', 'failed')) OR
                  (OLD.status = 'failed' AND NEW.status IN ('failed', 'processed'))) THEN
                RETURN NEW;
              END IF;
              RAISE EXCEPTION 'Intercom webhook source records are durable';
            END;
            $$;

            CREATE TRIGGER intercom_webhook_deliveries_protect_source
            BEFORE UPDATE OR DELETE ON intercom_webhook_deliveries
            FOR EACH ROW EXECUTE FUNCTION prevent_intercom_webhook_source_mutation();
            CREATE TRIGGER intercom_webhook_deliveries_no_truncate
            BEFORE TRUNCATE ON intercom_webhook_deliveries
            FOR EACH STATEMENT EXECUTE FUNCTION prevent_intercom_webhook_source_mutation();

            CREATE FUNCTION prevent_intercom_sync_operation_mutation()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              IF TG_OP = 'UPDATE' AND
                 OLD.id IS NOT DISTINCT FROM NEW.id AND
                 OLD.workspace_id IS NOT DISTINCT FROM NEW.workspace_id AND
                 OLD.intercom_connection_id IS NOT DISTINCT FROM NEW.intercom_connection_id AND
                 OLD.intercom_conversation_link_id IS NOT DISTINCT FROM NEW.intercom_conversation_link_id AND
                 OLD.membership_id IS NOT DISTINCT FROM NEW.membership_id AND
                 OLD.user_id IS NOT DISTINCT FROM NEW.user_id AND
                 OLD.operation_key IS NOT DISTINCT FROM NEW.operation_key AND
                 OLD.operation_kind IS NOT DISTINCT FROM NEW.operation_kind AND
                 OLD.payload IS NOT DISTINCT FROM NEW.payload AND
                 OLD.created_at IS NOT DISTINCT FROM NEW.created_at AND
                 ((OLD.status = 'pending' AND NEW.status = 'sending') OR
                  (OLD.status = 'sending' AND NEW.status IN ('completed', 'failed', 'unknown')) OR
                  (OLD.status = 'failed' AND NEW.status = 'sending')) THEN
                RETURN NEW;
              END IF;
              RAISE EXCEPTION 'Intercom sync operations are durable';
            END;
            $$;

            CREATE TRIGGER intercom_sync_operations_protect_source
            BEFORE UPDATE OR DELETE ON intercom_sync_operations
            FOR EACH ROW EXECUTE FUNCTION prevent_intercom_sync_operation_mutation();
            CREATE TRIGGER intercom_sync_operations_no_truncate
            BEFORE TRUNCATE ON intercom_sync_operations
            FOR EACH STATEMENT EXECUTE FUNCTION prevent_intercom_sync_operation_mutation();
          SQL
        end

        direction.down do
          execute "DROP TRIGGER IF EXISTS intercom_sync_operations_no_truncate ON intercom_sync_operations"
          execute "DROP TRIGGER IF EXISTS intercom_sync_operations_protect_source ON intercom_sync_operations"
          execute "DROP FUNCTION IF EXISTS prevent_intercom_sync_operation_mutation()"
          execute "DROP TRIGGER IF EXISTS intercom_webhook_deliveries_no_truncate ON intercom_webhook_deliveries"
          execute "DROP TRIGGER IF EXISTS intercom_webhook_deliveries_protect_source ON intercom_webhook_deliveries"
          execute "DROP FUNCTION IF EXISTS prevent_intercom_webhook_source_mutation()"
        end
      end
    end
end
