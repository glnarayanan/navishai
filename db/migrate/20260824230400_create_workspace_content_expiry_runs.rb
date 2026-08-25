class CreateWorkspaceContentExpiryRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_content_expiry_runs do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :cutoff_at, null: false
      t.string :status, null: false, default: "pending"
      t.integer :expired_record_count, null: false, default: 0
      t.string :failure_code
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :workspace_content_expiry_runs, [ :workspace_id, :created_at ]
    add_check_constraint :workspace_content_expiry_runs,
      "status IN ('pending', 'running', 'completed', 'failed')",
      name: "workspace_content_expiry_runs_status"
    add_check_constraint :workspace_content_expiry_runs,
      "expired_record_count >= 0",
      name: "workspace_content_expiry_runs_count"
    add_check_constraint :workspace_content_expiry_runs,
      "failure_code IS NULL OR failure_code ~ '^[a-z][a-z0-9_]{0,99}$'",
      name: "workspace_content_expiry_runs_failure"

    reversible do |direction|
      direction.up { create_expiry_function }
      direction.down { execute "DROP FUNCTION expire_workspace_content(bigint, timestamp without time zone)" }
    end
  end

  private
    def create_expiry_function
      execute <<~SQL
        CREATE FUNCTION expire_workspace_content(target_workspace_id bigint, cutoff timestamp without time zone)
        RETURNS integer
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = public, pg_temp
        AS $$
        DECLARE
          affected integer;
          total integer := 0;
          table_name text;
          expiry_tables text[] := ARRAY[
            'account_health_assessments', 'account_health_inputs', 'account_health_signals', 'accounts',
            'active_storage_attachments', 'active_storage_blobs',
            'case_notes', 'contacts', 'conversation_messages', 'conversations', 'crew_artifacts',
            'crew_task_events', 'crew_tasks', 'email_drafts', 'email_message_links', 'email_threads',
            'execution_events', 'execution_runs', 'health_scorecard_backtests',
            'health_scorecard_design_turns', 'health_scorecard_versions', 'inbound_email_deliveries',
            'intercom_conversation_links', 'intercom_drafts', 'intercom_outbound_deliveries', 'intercom_part_links',
            'intercom_sync_operations', 'intercom_webhook_deliveries', 'knowledge_source_versions',
            'knowledge_sources', 'memory_correction_proposals', 'memory_index_entries',
            'memory_proposals', 'memory_records', 'outbound_email_deliveries', 'public_web_extractions',
            'public_web_search_results', 'public_web_searches', 'source_identities',
            'source_identity_keys', 'stored_attachments', 'support_case_status_changes'
          ];
        BEGIN
          IF target_workspace_id IS NULL OR cutoff IS NULL THEN
            RAISE EXCEPTION 'workspace and cutoff are required';
          END IF;

          FOREACH table_name IN ARRAY expiry_tables LOOP
            EXECUTE format('LOCK TABLE %I IN ACCESS EXCLUSIVE MODE', table_name);
          END LOOP;
          FOREACH table_name IN ARRAY expiry_tables LOOP
            EXECUTE format('ALTER TABLE %I DISABLE TRIGGER USER', table_name);
          END LOOP;

          UPDATE accounts SET name = 'Expired account ' || id, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND name NOT LIKE 'Expired account %';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE contacts SET name = 'Expired contact ' || id, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND name NOT LIKE 'Expired contact %';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE source_identities
          SET source_record_id = 'expired-' || id, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND source_record_id NOT LIKE 'expired-%';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE source_identity_keys
          SET normalized_value = 'expired-' || id || '@invalid.example', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND normalized_value NOT LIKE 'expired-%@invalid.example';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE conversations SET subject = '[Expired by retention policy]', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND started_at < cutoff AND subject <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE conversation_messages
          SET body = '[Expired by retention policy]', external_author_name = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND occurred_at < cutoff AND
            (body <> '[Expired by retention policy]' OR external_author_name IS NOT NULL);
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE case_notes SET body = '[Expired by retention policy]', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND body <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE support_case_status_changes SET reason = '[Expired by retention policy]'
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND reason IS NOT NULL AND reason <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE inbound_email_deliveries
          SET source_message_id = '<expired-' || id || '@navishai.invalid>', content_sha256 = repeat('0', 64),
              raw_email = ''::bytea, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND received_at < cutoff AND octet_length(raw_email) > 0;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE email_threads SET thread_key = '<expired-thread-' || id || '@navishai.invalid>', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND thread_key NOT LIKE '<expired-thread-%@navishai.invalid>';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE email_message_links
          SET message_id = '<expired-link-' || id || '@navishai.invalid>', reply_to_address = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND message_id NOT LIKE '<expired-link-%@navishai.invalid>';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE email_drafts SET body = '[Expired by retention policy]', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND body <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE outbound_email_deliveries
          SET message_id = '<expired-outbound-' || id || '@navishai.invalid>', in_reply_to_message_id = NULL,
              from_address = 'expired@invalid.example', to_address = 'expired@invalid.example',
              subject = '[Expired by retention policy]', body = '[Expired by retention policy]', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND body <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE stored_attachments
          SET filename = 'expired-' || id || '.bin', content_sha256 = repeat('0', 64),
              detected_content_type = 'application/octet-stream', scan_status = 'rejected',
              scan_result_code = 'retention_expired', scanned_at = COALESCE(scanned_at, CURRENT_TIMESTAMP),
              updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND scan_result_code <> 'retention_expired';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE active_storage_blobs blobs
          SET filename = 'expired-' || blobs.id || '.bin', content_type = 'application/octet-stream',
              metadata = '{}', checksum = '47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=', byte_size = 0
          FROM active_storage_attachments attachments, stored_attachments stored
          WHERE attachments.record_type = 'StoredAttachment' AND attachments.name = 'file'
            AND attachments.record_id = stored.id AND attachments.blob_id = blobs.id
            AND stored.workspace_id = target_workspace_id AND stored.created_at < cutoff
            AND blobs.filename NOT LIKE 'expired-%.bin';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE knowledge_sources
          SET title = '[Expired by retention policy]',
              canonical_url = CASE WHEN source_kind = 'url' THEN 'https://expired.invalid/' || id ELSE NULL END,
              external_id = CASE WHEN source_kind = 'intercom_help_center' THEN 'expired-' || id ELSE NULL END,
              updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND title <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE knowledge_source_versions
          SET content = '[Expired by retention policy]', content_sha256 = repeat('0', 64),
              retrieved_from_url = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND content <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE crew_tasks SET title = '[Expired task]', input_context = '[Expired by retention policy]',
              expected_output = '[Expired by retention policy]', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND input_context <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE crew_task_events SET body = '[Expired by retention policy]', evidence_locator = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND
            (body IS DISTINCT FROM '[Expired by retention policy]' OR evidence_locator IS NOT NULL);
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE execution_runs
          SET input_context = '[Expired by retention policy]', output = CASE WHEN output IS NULL THEN NULL ELSE '[Expired by retention policy]' END,
              last_admission_error = NULL, runtime_selection_detail = NULL, memory_context_detail = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND
            (input_context IS DISTINCT FROM '[Expired by retention policy]' OR
             (output IS NOT NULL AND output <> '[Expired by retention policy]') OR
             last_admission_error IS NOT NULL OR runtime_selection_detail IS NOT NULL OR memory_context_detail IS NOT NULL);
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE execution_events SET data = '{}'::jsonb, payload_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND occurred_at < cutoff AND data <> '{}'::jsonb;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE crew_artifacts
          SET body = '[Expired by retention policy]', uncertainty = '[Expired by retention policy]', citations = '[]'::jsonb,
              conflicts = '[]'::jsonb, change_requests = '[]'::jsonb, payload_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND body <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE public_web_searches SET query = '[Expired by retention policy]', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND COALESCE(retrieved_at, created_at) < cutoff AND query <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE public_web_search_results
          SET title = '[Expired by retention policy]', url = 'https://expired.invalid/' || id,
              excerpt = '[Expired by retention policy]', content_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND COALESCE(retrieved_at, created_at) < cutoff AND title <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE public_web_extractions
          SET source_url = 'https://expired.invalid/' || id, final_url = 'https://expired.invalid/' || id,
              content = '[Expired by retention policy]', content_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND COALESCE(retrieved_at, created_at) < cutoff AND content <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE memory_records
          SET topic = '[Expired memory]', content = '[Expired by retention policy]', content_digest = repeat('0', 64),
              source_reference = 'retention-expired://' || memory_key, source_digest = repeat('0', 64),
              retention_policy = 'time_bound', retention_until = cutoff, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND observed_at < cutoff AND content <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE memory_proposals
          SET topic = '[Expired memory]', content = '[Expired by retention policy]', content_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND content <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE memory_correction_proposals
          SET content = '[Expired by retention policy]', content_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND content <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE memory_index_entries
          SET status = 'failed', external_document_id = NULL, external_status = NULL,
              failure_code = 'retention_expired', indexed_at = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND external_document_id IS NOT NULL;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE intercom_webhook_deliveries
          SET notification_id = 'expired-' || id, topic = 'expired', content_sha256 = repeat('0', 64),
              raw_payload = '{}'::bytea, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND received_at < cutoff AND octet_length(raw_payload) > 2;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE intercom_conversation_links
          SET remote_conversation_id = 'expired-' || id, remote_assignee_id = NULL, remote_assignee_name = NULL,
              source_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND remote_updated_at < cutoff AND remote_conversation_id NOT LIKE 'expired-%';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE intercom_part_links
          SET remote_part_id = 'expired-' || id, author_name = NULL, body = '[Expired by retention policy]',
              source_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND remote_created_at < cutoff AND body <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE intercom_sync_operations
          SET payload = '{}'::jsonb, remote_object_id = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND payload <> '{}'::jsonb;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE intercom_drafts SET body = '[Expired by retention policy]', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND body <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE intercom_outbound_deliveries
          SET remote_conversation_id = 'expired-' || id, source_part_id = NULL,
              remote_part_id = CASE WHEN status = 'sent' THEN 'expired-part-' || id ELSE NULL END,
              admin_id = NULL, body = '[Expired by retention policy]', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND body <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE account_health_inputs
          SET source_key = 'expired-' || id, source_locator = '[Expired by retention policy]',
              numeric_value = CASE WHEN value_kind = 'number' THEN 0 ELSE NULL END,
              date_value = CASE WHEN value_kind = 'date' THEN DATE '1970-01-01' ELSE NULL END,
              updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND observed_at < cutoff AND source_key NOT LIKE 'expired-%';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE account_health_signals
          SET source_locator = '[Expired by retention policy]',
              numeric_value = CASE WHEN value_kind = 'number' THEN 0 ELSE NULL END,
              date_value = CASE WHEN value_kind = 'date' THEN DATE '1970-01-01' ELSE NULL END,
              risk_points = 0, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND range_ends_at < cutoff AND source_locator <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE account_health_assessments
          SET score = 0, risk_level = 'healthy', renewal_on = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND calculated_at < cutoff AND (score <> 0 OR risk_level <> 'healthy' OR renewal_on IS NOT NULL);
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE health_scorecard_design_turns
          SET prompt = '[Expired by retention policy]', response = '[Expired by retention policy]', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND prompt <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE health_scorecard_versions
          SET design_prompt = '[Expired by retention policy]', explanation = '[Expired by retention policy]', updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND design_prompt <> '[Expired by retention policy]';
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          UPDATE health_scorecard_backtests SET results = '[]'::jsonb, source_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
          WHERE workspace_id = target_workspace_id AND created_at < cutoff AND results <> '[]'::jsonb;
          GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

          FOREACH table_name IN ARRAY expiry_tables LOOP
            EXECUTE format('ALTER TABLE %I ENABLE TRIGGER USER', table_name);
          END LOOP;
          RETURN total;
        END;
        $$;
        REVOKE ALL ON FUNCTION expire_workspace_content(bigint, timestamp without time zone) FROM PUBLIC;
      SQL
    end
end
