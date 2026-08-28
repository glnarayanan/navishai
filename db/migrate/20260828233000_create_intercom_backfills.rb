class CreateIntercomBackfills < ActiveRecord::Migration[8.1]
  def up
    create_manifests
    create_runs
    create_batches
    create_exceptions
    create_reports
    create_part_attachments
    extend_stored_attachment_sources
    extend_content_expiry
  end

  def down
    restore_content_expiry
    restore_stored_attachment_sources
    drop_table :intercom_part_attachments
    drop_table :intercom_backfill_reports
    drop_table :intercom_backfill_exceptions
    drop_table :intercom_backfill_batches
    drop_table :intercom_backfill_runs
    drop_table :intercom_backfill_manifests
  end

  private
    def create_manifests
      create_table :intercom_backfill_manifests do |t|
        t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
        t.bigint :intercom_connection_id, null: false
        t.bigint :created_by_membership_id, null: false
        t.bigint :created_by_user_id, null: false
        t.string :status, null: false, default: "current"
        t.string :source_digest, null: false
        t.jsonb :discovery_records, null: false, default: []
        t.jsonb :counts, null: false, default: {}
        t.datetime :available_from
        t.datetime :available_to
        t.datetime :discovered_at, null: false
        t.datetime :expires_at, null: false
        t.datetime :consumed_at
        t.datetime :expired_at
        t.timestamps
      end
      add_index :intercom_backfill_manifests, [ :workspace_id, :id ], unique: true
      add_index :intercom_backfill_manifests, [ :intercom_connection_id, :status, :created_at ],
        name: "index_intercom_backfill_manifests_for_connection"
      add_foreign_key :intercom_backfill_manifests, :intercom_connections,
        column: [ :workspace_id, :intercom_connection_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_intercom_backfill_manifests_connection"
      add_foreign_key :intercom_backfill_manifests, :memberships,
        column: [ :workspace_id, :created_by_membership_id, :created_by_user_id ],
        primary_key: [ :workspace_id, :id, :user_id ], name: "fk_intercom_backfill_manifests_actor"
      add_check_constraint :intercom_backfill_manifests,
        "status IN ('current', 'consumed', 'stale')", name: "intercom_backfill_manifests_status"
      add_check_constraint :intercom_backfill_manifests,
        "source_digest ~ '^[0-9a-f]{64}$' AND octet_length(discovery_records::text) <= 262144 AND " \
        "octet_length(counts::text) <= 8192 AND jsonb_typeof(discovery_records) = 'array' AND jsonb_typeof(counts) = 'object'",
        name: "intercom_backfill_manifests_bounds"
    end

    def create_runs
      create_table :intercom_backfill_runs do |t|
        t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
        t.bigint :intercom_connection_id, null: false
        t.bigint :intercom_backfill_manifest_id, null: false
        t.bigint :confirmed_by_membership_id, null: false
        t.bigint :confirmed_by_user_id, null: false
        t.string :status, null: false, default: "pending"
        t.string :source_digest, null: false
        t.integer :cursor_position, null: false, default: 0
        t.jsonb :counts, null: false, default: {}
        t.string :last_definite_remote_id
        t.string :last_definite_source_digest
        t.string :failure_code
        t.datetime :confirmed_at, null: false
        t.datetime :started_at
        t.datetime :completed_at
        t.datetime :expired_at
        t.timestamps
      end
      add_index :intercom_backfill_runs, [ :workspace_id, :id ], unique: true
      add_index :intercom_backfill_runs, :intercom_backfill_manifest_id, unique: true
      add_index :intercom_backfill_runs, [ :intercom_connection_id, :status, :created_at ],
        name: "index_intercom_backfill_runs_for_connection"
      add_foreign_key :intercom_backfill_runs, :intercom_connections,
        column: [ :workspace_id, :intercom_connection_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_intercom_backfill_runs_connection"
      add_foreign_key :intercom_backfill_runs, :intercom_backfill_manifests,
        column: [ :workspace_id, :intercom_backfill_manifest_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_intercom_backfill_runs_manifest"
      add_foreign_key :intercom_backfill_runs, :memberships,
        column: [ :workspace_id, :confirmed_by_membership_id, :confirmed_by_user_id ],
        primary_key: [ :workspace_id, :id, :user_id ], name: "fk_intercom_backfill_runs_actor"
      add_check_constraint :intercom_backfill_runs,
        "status IN ('pending', 'running', 'blocked', 'failed', 'completed') AND cursor_position >= 0",
        name: "intercom_backfill_runs_state"
      add_check_constraint :intercom_backfill_runs,
        "source_digest ~ '^[0-9a-f]{64}$' AND " \
        "(last_definite_source_digest IS NULL OR last_definite_source_digest ~ '^[0-9a-f]{64}$') AND " \
        "octet_length(counts::text) <= 8192 AND jsonb_typeof(counts) = 'object' AND " \
        "(failure_code IS NULL OR failure_code ~ '^[a-z][a-z0-9_]{0,99}$')",
        name: "intercom_backfill_runs_bounds"
    end

    def create_batches
      create_table :intercom_backfill_batches do |t|
        t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
        t.bigint :intercom_backfill_run_id, null: false
        t.integer :start_position, null: false
        t.integer :end_position, null: false
        t.integer :attempt_number, null: false, default: 1
        t.string :status, null: false
        t.string :source_digest, null: false
        t.jsonb :counts, null: false, default: {}
        t.string :last_definite_remote_id
        t.datetime :started_at, null: false
        t.datetime :completed_at
        t.datetime :expired_at
        t.timestamps
      end
      add_index :intercom_backfill_batches, [ :workspace_id, :id ], unique: true
      add_index :intercom_backfill_batches, [ :intercom_backfill_run_id, :start_position, :attempt_number ], unique: true,
        name: "index_intercom_backfill_batches_boundary"
      add_foreign_key :intercom_backfill_batches, :intercom_backfill_runs,
        column: [ :workspace_id, :intercom_backfill_run_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_intercom_backfill_batches_run"
      add_check_constraint :intercom_backfill_batches,
        "status IN ('running', 'completed', 'blocked', 'failed') AND start_position >= 0 AND end_position >= start_position AND attempt_number > 0 AND " \
        "source_digest ~ '^[0-9a-f]{64}$' AND octet_length(counts::text) <= 8192 AND jsonb_typeof(counts) = 'object'",
        name: "intercom_backfill_batches_state"
    end

    def create_exceptions
      create_table :intercom_backfill_exceptions do |t|
        t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
        t.bigint :intercom_backfill_manifest_id, null: false
        t.bigint :intercom_backfill_run_id
        t.bigint :source_identity_id
        t.string :remote_record_type, null: false
        t.string :remote_record_id, null: false
        t.string :source_digest, null: false
        t.string :exception_kind, null: false
        t.string :status, null: false, default: "open"
        t.string :recovery_action, null: false
        t.text :detail, null: false
        t.datetime :resolved_at
        t.datetime :expired_at
        t.timestamps
      end
      add_index :intercom_backfill_exceptions, [ :workspace_id, :id ], unique: true
      add_index :intercom_backfill_exceptions,
        [ :intercom_backfill_manifest_id, :remote_record_type, :remote_record_id, :exception_kind ],
        unique: true, name: "index_intercom_backfill_exceptions_identity"
      add_foreign_key :intercom_backfill_exceptions, :intercom_backfill_manifests,
        column: [ :workspace_id, :intercom_backfill_manifest_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_intercom_backfill_exceptions_manifest"
      add_foreign_key :intercom_backfill_exceptions, :intercom_backfill_runs,
        column: [ :workspace_id, :intercom_backfill_run_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_intercom_backfill_exceptions_run"
      add_foreign_key :intercom_backfill_exceptions, :source_identities,
        column: [ :workspace_id, :source_identity_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_intercom_backfill_exceptions_identity"
      add_check_constraint :intercom_backfill_exceptions,
        "remote_record_type IN ('conversation', 'identity', 'attachment', 'field') AND " \
        "exception_kind IN ('ambiguous_identity', 'source_changed', 'unsupported_field', 'attachment_rejected', 'attachment_unavailable', 'persistence_failed') AND " \
        "status IN ('open', 'resolved') AND recovery_action IN ('review_identity', 'restart_preview', 'inspect_source', 'inspect_attachment', 'resume')",
        name: "intercom_backfill_exceptions_kind"
      add_check_constraint :intercom_backfill_exceptions,
        "source_digest ~ '^[0-9a-f]{64}$' AND octet_length(remote_record_id) BETWEEN 1 AND 255 AND octet_length(detail) BETWEEN 1 AND 500",
        name: "intercom_backfill_exceptions_bounds"
    end

    def create_reports
      create_table :intercom_backfill_reports do |t|
        t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
        t.bigint :intercom_backfill_run_id, null: false
        t.string :status, null: false
        t.jsonb :counts, null: false
        t.string :report_digest, null: false
        t.datetime :generated_at, null: false
        t.timestamps
      end
      add_index :intercom_backfill_reports, [ :workspace_id, :id ], unique: true
      add_index :intercom_backfill_reports, :intercom_backfill_run_id, unique: true
      add_foreign_key :intercom_backfill_reports, :intercom_backfill_runs,
        column: [ :workspace_id, :intercom_backfill_run_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_intercom_backfill_reports_run"
      add_check_constraint :intercom_backfill_reports,
        "status IN ('partial', 'complete') AND report_digest ~ '^[0-9a-f]{64}$' AND " \
        "octet_length(counts::text) <= 8192 AND jsonb_typeof(counts) = 'object'",
        name: "intercom_backfill_reports_bounds"
    end

    def create_part_attachments
      create_table :intercom_part_attachments do |t|
        t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
        t.bigint :intercom_part_link_id, null: false
        t.bigint :stored_attachment_id, null: false
        t.string :remote_attachment_id, null: false
        t.timestamps
      end
      add_index :intercom_part_attachments, [ :workspace_id, :id ], unique: true
      add_index :intercom_part_attachments, [ :intercom_part_link_id, :remote_attachment_id ], unique: true,
        name: "index_intercom_part_attachments_remote"
      add_foreign_key :intercom_part_attachments, :intercom_part_links,
        column: [ :workspace_id, :intercom_part_link_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_intercom_part_attachments_part"
      add_foreign_key :intercom_part_attachments, :stored_attachments,
        column: [ :workspace_id, :stored_attachment_id ], primary_key: [ :workspace_id, :id ],
        name: "fk_intercom_part_attachments_attachment"
      add_check_constraint :intercom_part_attachments,
        "octet_length(remote_attachment_id) BETWEEN 1 AND 255", name: "intercom_part_attachments_remote_id"
    end

    def extend_stored_attachment_sources
      remove_check_constraint :stored_attachments, name: "stored_attachments_source"
      remove_check_constraint :stored_attachments, name: "stored_attachments_actor"
      add_check_constraint :stored_attachments,
        "source IN ('inbound_email', 'user_upload', 'intercom_import')", name: "stored_attachments_source"
      add_check_constraint :stored_attachments,
        "(source IN ('inbound_email', 'intercom_import') AND uploaded_by_membership_id IS NULL AND uploaded_by_user_id IS NULL) OR " \
        "(source = 'user_upload' AND uploaded_by_membership_id IS NOT NULL AND uploaded_by_user_id IS NOT NULL)",
        name: "stored_attachments_actor"
    end

    def restore_stored_attachment_sources
      remove_check_constraint :stored_attachments, name: "stored_attachments_source"
      remove_check_constraint :stored_attachments, name: "stored_attachments_actor"
      add_check_constraint :stored_attachments,
        "source IN ('inbound_email', 'user_upload')", name: "stored_attachments_source"
      add_check_constraint :stored_attachments,
        "(source = 'inbound_email' AND uploaded_by_membership_id IS NULL AND uploaded_by_user_id IS NULL) OR " \
        "(source = 'user_upload' AND uploaded_by_membership_id IS NOT NULL AND uploaded_by_user_id IS NOT NULL)",
        name: "stored_attachments_actor"
    end

    def extend_content_expiry
      execute <<~SQL
        ALTER FUNCTION expire_workspace_content(bigint, timestamp without time zone)
          RENAME TO expire_workspace_content_before_intercom_backfill;
        CREATE FUNCTION expire_workspace_content(target_workspace_id bigint, cutoff timestamp without time zone)
        RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
        DECLARE affected integer; total integer;
        BEGIN
          total := expire_workspace_content_before_intercom_backfill(target_workspace_id, cutoff);
          LOCK TABLE intercom_backfill_manifests, intercom_backfill_runs, intercom_backfill_batches,
            intercom_backfill_exceptions, intercom_part_attachments IN ACCESS EXCLUSIVE MODE;
          UPDATE intercom_backfill_manifests
            SET discovery_records = '[]'::jsonb, source_digest = repeat('0', 64), expired_at = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP
            WHERE workspace_id = target_workspace_id AND discovered_at < cutoff AND expired_at IS NULL;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;
          UPDATE intercom_backfill_runs
            SET last_definite_remote_id = NULL, last_definite_source_digest = NULL, expired_at = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP
            WHERE workspace_id = target_workspace_id AND confirmed_at < cutoff AND expired_at IS NULL;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;
          UPDATE intercom_backfill_batches
            SET last_definite_remote_id = NULL, expired_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
            WHERE workspace_id = target_workspace_id AND started_at < cutoff AND expired_at IS NULL;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;
          UPDATE intercom_backfill_exceptions
            SET remote_record_id = 'expired-' || id, source_digest = repeat('0', 64),
                detail = '[Expired by retention policy]', expired_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
            WHERE workspace_id = target_workspace_id AND created_at < cutoff AND expired_at IS NULL;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;
          UPDATE intercom_part_attachments links SET remote_attachment_id = 'expired-' || links.id,
            updated_at = CURRENT_TIMESTAMP
            WHERE workspace_id = target_workspace_id AND created_at < cutoff AND remote_attachment_id NOT LIKE 'expired-%';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;
          RETURN total;
        END;
        $$;
      SQL
    end

    def restore_content_expiry
      execute <<~SQL
        DROP FUNCTION expire_workspace_content(bigint, timestamp without time zone);
        ALTER FUNCTION expire_workspace_content_before_intercom_backfill(bigint, timestamp without time zone)
          RENAME TO expire_workspace_content;
      SQL
    end
end
