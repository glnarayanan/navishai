class CreateAttachmentRecords < ActiveRecord::Migration[8.1]
  def change
    add_index :active_storage_attachments, [ :record_type, :record_id, :name ],
      unique: true, where: "record_type = 'StoredAttachment'",
      name: "index_active_storage_stored_attachment_file"

    create_table :stored_attachments do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :uploaded_by_membership_id
      t.bigint :uploaded_by_user_id
      t.string :source, null: false
      t.string :filename, null: false
      t.bigint :byte_size, null: false
      t.string :content_sha256, null: false
      t.string :detected_content_type, null: false
      t.string :scan_status, null: false
      t.string :scan_result_code
      t.datetime :scanned_at
      t.timestamps
    end
    add_index :stored_attachments, [ :workspace_id, :id ], unique: true
    add_foreign_key :stored_attachments, :memberships,
      column: [ :workspace_id, :uploaded_by_membership_id, :uploaded_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :stored_attachments, :users, column: :uploaded_by_user_id
    add_check_constraint :stored_attachments,
      "source IN ('inbound_email', 'user_upload')", name: "stored_attachments_source"
    add_check_constraint :stored_attachments,
      "scan_status IN ('quarantined', 'available', 'rejected')", name: "stored_attachments_scan_status"
    add_check_constraint :stored_attachments,
      "byte_size BETWEEN 1 AND 5242880", name: "stored_attachments_size"
    add_check_constraint :stored_attachments,
      "content_sha256 ~ '^[0-9a-f]{64}$'", name: "stored_attachments_sha256"
    add_check_constraint :stored_attachments,
      "(source = 'inbound_email' AND uploaded_by_membership_id IS NULL AND uploaded_by_user_id IS NULL) OR " \
      "(source = 'user_upload' AND uploaded_by_membership_id IS NOT NULL AND uploaded_by_user_id IS NOT NULL)",
      name: "stored_attachments_actor"
    add_check_constraint :stored_attachments,
      "scan_result_code IS NOT NULL AND scan_result_code <> '' AND " \
      "((scan_status = 'quarantined' AND scanned_at IS NULL) OR " \
      "(scan_status IN ('available', 'rejected') AND scanned_at IS NOT NULL))",
      name: "stored_attachments_scan_state"

    create_table :conversation_message_attachments do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :conversation_id, null: false
      t.bigint :conversation_message_id, null: false
      t.bigint :stored_attachment_id, null: false
      t.timestamps
    end
    add_index :conversation_message_attachments, [ :workspace_id, :id ], unique: true
    add_index :conversation_message_attachments, [ :conversation_message_id, :stored_attachment_id ], unique: true,
      name: "index_message_attachments_on_message_and_attachment"
    add_foreign_key :conversation_message_attachments, :conversation_messages,
      column: [ :workspace_id, :conversation_id, :conversation_message_id ],
      primary_key: [ :workspace_id, :conversation_id, :id ]
    add_foreign_key :conversation_message_attachments, :stored_attachments,
      column: [ :workspace_id, :stored_attachment_id ], primary_key: [ :workspace_id, :id ]

    create_table :email_draft_attachments do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :email_draft_id, null: false
      t.bigint :stored_attachment_id, null: false
      t.timestamps
    end
    add_index :email_draft_attachments, [ :workspace_id, :id ], unique: true
    add_index :email_draft_attachments, [ :email_draft_id, :stored_attachment_id ], unique: true
    add_foreign_key :email_draft_attachments, :email_drafts,
      column: [ :workspace_id, :email_draft_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :email_draft_attachments, :stored_attachments,
      column: [ :workspace_id, :stored_attachment_id ], primary_key: [ :workspace_id, :id ]

    create_table :outbound_email_delivery_attachments do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :outbound_email_delivery_id, null: false
      t.bigint :stored_attachment_id, null: false
      t.timestamps
    end
    add_index :outbound_email_delivery_attachments, [ :workspace_id, :id ], unique: true,
      name: "index_delivery_attachments_on_workspace_and_id"
    add_index :outbound_email_delivery_attachments,
      [ :outbound_email_delivery_id, :stored_attachment_id ], unique: true,
      name: "index_delivery_attachments_on_delivery_and_attachment"
    add_foreign_key :outbound_email_delivery_attachments, :outbound_email_deliveries,
      column: [ :workspace_id, :outbound_email_delivery_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :outbound_email_delivery_attachments, :stored_attachments,
      column: [ :workspace_id, :stored_attachment_id ], primary_key: [ :workspace_id, :id ]

    protect_attachment_records
  end

  private
    def protect_attachment_records
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION protect_stored_attachment()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              IF TG_OP = 'UPDATE' AND
                 ROW(OLD.id, OLD.workspace_id, OLD.uploaded_by_membership_id, OLD.uploaded_by_user_id,
                     OLD.source, OLD.filename, OLD.byte_size, OLD.content_sha256,
                     OLD.detected_content_type, OLD.created_at)
                 IS NOT DISTINCT FROM
                 ROW(NEW.id, NEW.workspace_id, NEW.uploaded_by_membership_id, NEW.uploaded_by_user_id,
                     NEW.source, NEW.filename, NEW.byte_size, NEW.content_sha256,
                     NEW.detected_content_type, NEW.created_at) AND
                 (ROW(OLD.scan_status, OLD.scan_result_code, OLD.scanned_at)
                    IS NOT DISTINCT FROM
                  ROW(NEW.scan_status, NEW.scan_result_code, NEW.scanned_at) OR
                  (OLD.scan_status = 'quarantined' AND NEW.scan_status IN ('available', 'rejected'))) THEN
                RETURN NEW;
              END IF;
              RAISE EXCEPTION 'stored attachment records are durable';
            END;
            $$;

            CREATE TRIGGER stored_attachments_protect_record
            BEFORE UPDATE OR DELETE ON stored_attachments
            FOR EACH ROW EXECUTE FUNCTION protect_stored_attachment();
            CREATE TRIGGER stored_attachments_no_truncate
            BEFORE TRUNCATE ON stored_attachments
            FOR EACH STATEMENT EXECUTE FUNCTION protect_stored_attachment();

            CREATE FUNCTION protect_attachment_join()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              RAISE EXCEPTION 'attachment history is append only';
            END;
            $$;

            CREATE TRIGGER conversation_message_attachments_append_only
            BEFORE UPDATE OR DELETE ON conversation_message_attachments
            FOR EACH ROW EXECUTE FUNCTION protect_attachment_join();
            CREATE TRIGGER conversation_message_attachments_no_truncate
            BEFORE TRUNCATE ON conversation_message_attachments
            FOR EACH STATEMENT EXECUTE FUNCTION protect_attachment_join();
            CREATE TRIGGER outbound_email_delivery_attachments_append_only
            BEFORE UPDATE OR DELETE ON outbound_email_delivery_attachments
            FOR EACH ROW EXECUTE FUNCTION protect_attachment_join();
            CREATE TRIGGER outbound_email_delivery_attachments_no_truncate
            BEFORE TRUNCATE ON outbound_email_delivery_attachments
            FOR EACH STATEMENT EXECUTE FUNCTION protect_attachment_join();

            CREATE FUNCTION enforce_clean_outbound_attachment()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              IF TG_TABLE_NAME = 'conversation_message_attachments' THEN
                IF NOT EXISTS (
                  SELECT 1 FROM conversation_messages
                  WHERE id = NEW.conversation_message_id
                    AND direction = 'outbound'
                ) THEN
                  RETURN NEW;
                END IF;
              END IF;
              IF NOT EXISTS (
                SELECT 1 FROM stored_attachments
                WHERE id = NEW.stored_attachment_id
                  AND workspace_id = NEW.workspace_id
                  AND scan_status = 'available'
              ) THEN
                RAISE EXCEPTION 'outbound attachments must be available';
              END IF;
              RETURN NEW;
            END;
            $$;

            CREATE TRIGGER outbound_email_delivery_attachments_require_clean
            BEFORE INSERT ON outbound_email_delivery_attachments
            FOR EACH ROW EXECUTE FUNCTION enforce_clean_outbound_attachment();
            CREATE TRIGGER outbound_message_attachments_require_clean
            BEFORE INSERT ON conversation_message_attachments
            FOR EACH ROW EXECUTE FUNCTION enforce_clean_outbound_attachment();

            CREATE FUNCTION protect_stored_attachment_file()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              IF TG_OP = 'TRUNCATE' THEN
                IF EXISTS (SELECT 1 FROM active_storage_attachments WHERE record_type = 'StoredAttachment') THEN
                  RAISE EXCEPTION 'stored attachment files are durable';
                END IF;
                RETURN NULL;
              END IF;
              IF TG_TABLE_NAME = 'active_storage_attachments' THEN
                IF OLD.record_type = 'StoredAttachment' THEN
                  IF TG_OP = 'UPDATE' AND
                     ROW(OLD.id, OLD.name, OLD.record_type, OLD.record_id, OLD.blob_id, OLD.created_at)
                     IS NOT DISTINCT FROM
                     ROW(NEW.id, NEW.name, NEW.record_type, NEW.record_id, NEW.blob_id, NEW.created_at) THEN
                    RETURN NEW;
                  END IF;
                  RAISE EXCEPTION 'stored attachment files are durable';
                END IF;
              ELSIF EXISTS (
                SELECT 1 FROM active_storage_attachments
                WHERE blob_id = OLD.id AND record_type = 'StoredAttachment'
              ) THEN
                IF TG_OP = 'UPDATE' AND
                   ROW(OLD.id, OLD.key, OLD.filename, OLD.content_type,
                       OLD.service_name, OLD.byte_size, OLD.checksum, OLD.created_at)
                   IS NOT DISTINCT FROM
                   ROW(NEW.id, NEW.key, NEW.filename, NEW.content_type,
                       NEW.service_name, NEW.byte_size, NEW.checksum, NEW.created_at) THEN
                  RETURN NEW;
                END IF;
                RAISE EXCEPTION 'stored attachment files are durable';
              END IF;
              RETURN COALESCE(NEW, OLD);
            END;
            $$;

            CREATE TRIGGER active_storage_attachments_protect_stored
            BEFORE UPDATE OR DELETE ON active_storage_attachments
            FOR EACH ROW EXECUTE FUNCTION protect_stored_attachment_file();
            CREATE TRIGGER active_storage_attachments_no_stored_truncate
            BEFORE TRUNCATE ON active_storage_attachments
            FOR EACH STATEMENT EXECUTE FUNCTION protect_stored_attachment_file();
            CREATE TRIGGER active_storage_blobs_protect_stored
            BEFORE UPDATE OR DELETE ON active_storage_blobs
            FOR EACH ROW EXECUTE FUNCTION protect_stored_attachment_file();
            CREATE TRIGGER active_storage_blobs_no_stored_truncate
            BEFORE TRUNCATE ON active_storage_blobs
            FOR EACH STATEMENT EXECUTE FUNCTION protect_stored_attachment_file();
          SQL
        end

        direction.down do
          execute "DROP FUNCTION IF EXISTS protect_stored_attachment_file() CASCADE"
          execute "DROP FUNCTION IF EXISTS enforce_clean_outbound_attachment() CASCADE"
          execute "DROP FUNCTION IF EXISTS protect_attachment_join() CASCADE"
          execute "DROP FUNCTION IF EXISTS protect_stored_attachment() CASCADE"
        end
      end
    end
end
