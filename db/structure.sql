SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: check_governed_policy_proposal_subject_count(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_governed_policy_proposal_subject_count() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM validate_governed_policy_subject_count(NEW.id);
  RETURN NEW;
END;
$$;


--
-- Name: check_governed_policy_subject_count(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_governed_policy_subject_count() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM validate_governed_policy_subject_count(COALESCE(NEW.governed_policy_proposal_id, OLD.governed_policy_proposal_id));
  RETURN COALESCE(NEW, OLD);
END;
$$;


--
-- Name: enforce_active_knowledge_source(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_active_knowledge_source() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM 1 FROM knowledge_sources
  WHERE id = NEW.knowledge_source_id
    AND workspace_id = NEW.workspace_id
    AND deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'knowledge source must be active';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_clean_outbound_attachment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_clean_outbound_attachment() RETURNS trigger
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


--
-- Name: enforce_notification_event_workspace(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_notification_event_workspace() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: expire_workspace_audit(bigint, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.expire_workspace_audit(target_workspace_id bigint, cutoff timestamp without time zone) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE affected integer;
BEGIN
  IF target_workspace_id IS NULL OR cutoff IS NULL THEN
    RAISE EXCEPTION 'workspace and cutoff are required';
  END IF;
  LOCK TABLE audit_events IN ACCESS EXCLUSIVE MODE;
  ALTER TABLE audit_events DISABLE TRIGGER USER;
  UPDATE audit_events
  SET actor_id = NULL, actor_kind = 'system', metadata = '{}'::jsonb,
      request_id = NULL, ip_address = NULL, expired_at = CURRENT_TIMESTAMP
  WHERE workspace_id = target_workspace_id AND occurred_at < cutoff AND expired_at IS NULL;
  GET DIAGNOSTICS affected = ROW_COUNT;
  ALTER TABLE audit_events ENABLE TRIGGER USER;
  RETURN affected;
END;
$$;


--
-- Name: expire_workspace_content(bigint, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.expire_workspace_content(target_workspace_id bigint, cutoff timestamp without time zone) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE affected integer; total integer;
BEGIN
  total := expire_workspace_content_before_governed_policy(target_workspace_id, cutoff);
  LOCK TABLE governed_policy_proposals, governed_policy_previews, governed_policy_publications
    IN ACCESS EXCLUSIVE MODE;
  ALTER TABLE governed_policy_proposals DISABLE TRIGGER USER;
  ALTER TABLE governed_policy_previews DISABLE TRIGGER USER;
  ALTER TABLE governed_policy_publications DISABLE TRIGGER USER;

  UPDATE governed_policy_proposals
    SET reason = '[Expired by retention policy]', expired_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE workspace_id = target_workspace_id AND created_at < cutoff AND expired_at IS NULL;
  GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

  UPDATE governed_policy_previews
    SET source_snapshot = '{"retention":"expired"}'::jsonb,
        results = COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'subject_kind', item->>'subject_kind', 'subject_id', item->'subject_id',
            'old_decision', '{"retention":"expired"}'::jsonb,
            'proposed_decision', '{"retention":"expired"}'::jsonb,
            'changes', '[]'::jsonb, 'facts', '[]'::jsonb, 'result', 'expired'
          ) ORDER BY ordinal)
          FROM jsonb_array_elements(results) WITH ORDINALITY AS values(item, ordinal)
        ), '[]'::jsonb),
        expired_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
    WHERE workspace_id = target_workspace_id AND previewed_at < cutoff AND expired_at IS NULL;
  GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

  UPDATE governed_policy_publications
    SET reason = '[Expired by retention policy]', expired_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE workspace_id = target_workspace_id AND published_at < cutoff AND expired_at IS NULL;
  GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

  ALTER TABLE governed_policy_publications ENABLE TRIGGER USER;
  ALTER TABLE governed_policy_previews ENABLE TRIGGER USER;
  ALTER TABLE governed_policy_proposals ENABLE TRIGGER USER;
  RETURN total;
END;
$$;


--
-- Name: expire_workspace_content_before_governed_policy(bigint, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.expire_workspace_content_before_governed_policy(target_workspace_id bigint, cutoff timestamp without time zone) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: expire_workspace_content_before_intercom_backfill(bigint, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.expire_workspace_content_before_intercom_backfill(target_workspace_id bigint, cutoff timestamp without time zone) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  affected integer;
  total integer;
BEGIN
  total := expire_workspace_content_before_interventions(target_workspace_id, cutoff);
  LOCK TABLE customer_success_interventions, customer_success_intervention_outcome_reviews
    IN ACCESS EXCLUSIVE MODE;
  ALTER TABLE customer_success_interventions DISABLE TRIGGER USER;
  ALTER TABLE customer_success_intervention_outcome_reviews DISABLE TRIGGER USER;

  UPDATE customer_success_interventions AS interventions
  SET expected_observable_change = '[Expired by retention policy]',
      reason = '[Expired by retention policy]',
      abandonment_reason = CASE WHEN abandonment_reason IS NULL THEN NULL ELSE '[Expired by retention policy]' END,
      supporting_evidence = COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'kind', evidence->>'kind',
          'label', '[Expired by retention policy]',
          'locator', format(
            'retention-expired://customer-success-interventions/%s/evidence/%s',
            interventions.id, evidence_position
          )
        ) ORDER BY evidence_position)
        FROM jsonb_array_elements(interventions.supporting_evidence)
          WITH ORDINALITY AS evidence_items(evidence, evidence_position)
      ), '[]'::jsonb),
      updated_at = CURRENT_TIMESTAMP
  WHERE workspace_id = target_workspace_id AND proposed_at < cutoff AND
    expected_observable_change <> '[Expired by retention policy]';
  GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

  UPDATE customer_success_intervention_outcome_reviews
  SET before_snapshot = '{"retention":"expired"}'::jsonb,
      after_snapshot = '{"retention":"expired"}'::jsonb,
      changed_facts = '[]'::jsonb,
      unchanged_facts = '[]'::jsonb,
      uncertainty = '[Expired by retention policy]',
      observed_association = '[Expired by retention policy]',
      updated_at = CURRENT_TIMESTAMP
  WHERE workspace_id = target_workspace_id AND reviewed_at < cutoff AND
    before_snapshot <> '{"retention":"expired"}'::jsonb;
  GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

  ALTER TABLE customer_success_intervention_outcome_reviews ENABLE TRIGGER USER;
  ALTER TABLE customer_success_interventions ENABLE TRIGGER USER;
  RETURN total;
END;
$$;


--
-- Name: expire_workspace_content_before_interventions(bigint, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.expire_workspace_content_before_interventions(target_workspace_id bigint, cutoff timestamp without time zone) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
  SET input_context = '[Expired by retention policy]',
      output = CASE WHEN output IS NULL THEN NULL ELSE '[Expired by retention policy]' END,
      last_admission_error = NULL,
      runtime_selection_detail = '[Expired by retention policy]',
      memory_context_detail = CASE
        WHEN memory_context_status = 'degraded' THEN '[Expired by retention policy]'
        ELSE NULL
      END,
      updated_at = CURRENT_TIMESTAMP
  WHERE workspace_id = target_workspace_id AND created_at < cutoff AND
    (input_context IS DISTINCT FROM '[Expired by retention policy]' OR
     (output IS NOT NULL AND output <> '[Expired by retention policy]') OR
     last_admission_error IS NOT NULL OR
     runtime_selection_detail IS DISTINCT FROM '[Expired by retention policy]' OR
     memory_context_detail IS DISTINCT FROM CASE
       WHEN memory_context_status = 'degraded' THEN '[Expired by retention policy]'
       ELSE NULL
     END);
  GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

  UPDATE execution_events SET data = '{}'::jsonb, payload_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
  WHERE workspace_id = target_workspace_id AND occurred_at < cutoff AND data <> '{}'::jsonb;
  GET DIAGNOSTICS affected = ROW_COUNT; total := total + affected;

  UPDATE crew_artifacts AS artifacts
  SET body = '[Expired by retention policy]', uncertainty = '[Expired by retention policy]',
      citations = '[]'::jsonb, conflicts = '[]'::jsonb, change_requests = '[]'::jsonb,
      required_facts = CASE WHEN schema_version = 2 THEN COALESCE((
        SELECT jsonb_agg(to_jsonb('expired_claim_' || claim_position) ORDER BY claim_position)
        FROM jsonb_array_elements(artifacts.material_claims) WITH ORDINALITY AS claims(claim, claim_position)
        WHERE artifacts.required_facts ? (claim->>'key')
      ), '[]'::jsonb) ELSE required_facts END,
      material_claims = CASE WHEN schema_version = 2 THEN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'key', 'expired_claim_' || claim_position,
          'category', claim->>'category',
          'text', '[Expired by retention policy]',
          'state', CASE
            WHEN jsonb_array_length(claim->'evidence') = 0 THEN 'refused'
            WHEN claim->>'state' = 'supported' THEN 'uncertain'
            ELSE claim->>'state'
          END,
          'evidence', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'kind', evidence->>'kind',
              'locator', format(
                'retention-expired://crew-artifacts/%s/claims/%s/evidence/%s',
                artifacts.id, claim_position, evidence_position
              ),
              'status', 'expired',
              'observed_at', NULL,
              'valid_until', NULL,
              'fresh_until', NULL
            ) ORDER BY evidence_position)
            FROM jsonb_array_elements(claim->'evidence') WITH ORDINALITY AS evidence_items(evidence, evidence_position)
          ), '[]'::jsonb)
        ) ORDER BY claim_position)
        FROM jsonb_array_elements(artifacts.material_claims) WITH ORDINALITY AS claims(claim, claim_position)
      ), '[]'::jsonb) ELSE material_claims END,
      proposed_actions = CASE WHEN schema_version = 2 THEN '[]'::jsonb ELSE proposed_actions END,
      contract_blockers = CASE WHEN schema_version = 2 THEN COALESCE((
        SELECT jsonb_agg(blocker || jsonb_build_object(
          'claim_key', NULL,
          'message', '[Expired by retention policy]',
          'remediation', '[Expired by retention policy]'
        ) ORDER BY blocker_position)
        FROM jsonb_array_elements(artifacts.contract_blockers) WITH ORDINALITY AS blockers(blocker, blocker_position)
      ), '[]'::jsonb) ELSE contract_blockers END,
      payload_digest = repeat('0', 64), updated_at = CURRENT_TIMESTAMP
  WHERE workspace_id = target_workspace_id AND created_at < cutoff AND (
    body <> '[Expired by retention policy]' OR uncertainty <> '[Expired by retention policy]' OR
    citations <> '[]'::jsonb OR conflicts <> '[]'::jsonb OR change_requests <> '[]'::jsonb OR
    (schema_version = 2 AND (
      proposed_actions <> '[]'::jsonb OR
      EXISTS (
        SELECT 1 FROM jsonb_array_elements(material_claims) AS claims(claim)
        WHERE claim->>'text' <> '[Expired by retention policy]' OR
          claim->>'key' NOT LIKE 'expired_claim_%' OR
          EXISTS (
            SELECT 1 FROM jsonb_array_elements(claim->'evidence') AS evidence_items(evidence)
            WHERE evidence->>'locator' NOT LIKE 'retention-expired://crew-artifacts/%'
          )
      ) OR
      EXISTS (
        SELECT 1 FROM jsonb_array_elements(contract_blockers) AS blockers(blocker)
        WHERE blocker->>'message' <> '[Expired by retention policy]' OR
          blocker->>'remediation' <> '[Expired by retention policy]' OR
          blocker->'claim_key' <> 'null'::jsonb
      )
    ))
  );
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

  UPDATE memory_index_entries AS entries
  SET status = 'failed', external_document_id = NULL, external_status = NULL,
      failure_code = 'retention_expired', attempt_count = GREATEST(attempt_count, 1),
      last_attempted_at = COALESCE(last_attempted_at, CURRENT_TIMESTAMP),
      indexed_at = NULL, updated_at = CURRENT_TIMESTAMP
  WHERE entries.workspace_id = target_workspace_id AND EXISTS (
    SELECT 1 FROM memory_records AS records
    WHERE records.workspace_id = target_workspace_id AND records.id = entries.memory_record_id
      AND records.observed_at < cutoff
  ) AND (entries.status <> 'failed' OR entries.failure_code <> 'retention_expired');
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


--
-- Name: prevent_audit_event_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_audit_event_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'audit events are append-only';
END;
$$;


--
-- Name: prevent_helpdesk_record_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_helpdesk_record_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'helpdesk records are append-only';
END;
$$;


--
-- Name: prevent_inbound_email_source_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_inbound_email_source_mutation() RETURNS trigger
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


--
-- Name: prevent_intercom_sync_operation_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_intercom_sync_operation_mutation() RETURNS trigger
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


--
-- Name: prevent_intercom_webhook_source_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_intercom_webhook_source_mutation() RETURNS trigger
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


--
-- Name: prevent_used_sla_configuration_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_used_sla_configuration_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  referenced boolean;
  calendar_id bigint;
BEGIN
  IF TG_TABLE_NAME = 'sla_policies' THEN
    SELECT EXISTS (SELECT 1 FROM case_slas WHERE sla_policy_id = OLD.id) INTO referenced;
    IF referenced AND (TG_OP = 'DELETE' OR
       OLD.workspace_id IS DISTINCT FROM NEW.workspace_id OR
       OLD.service_calendar_id IS DISTINCT FROM NEW.service_calendar_id OR
       OLD.priority IS DISTINCT FROM NEW.priority OR
       OLD.first_response_minutes IS DISTINCT FROM NEW.first_response_minutes OR
       OLD.resolution_minutes IS DISTINCT FROM NEW.resolution_minutes OR
       OLD.warning_percent IS DISTINCT FROM NEW.warning_percent) THEN
      RAISE EXCEPTION 'used SLA policy settings are immutable';
    END IF;
  ELSIF TG_TABLE_NAME = 'service_calendars' THEN
    SELECT EXISTS (
      SELECT 1 FROM case_slas
      JOIN sla_policies ON sla_policies.id = case_slas.sla_policy_id
      WHERE sla_policies.service_calendar_id = OLD.id
    ) INTO referenced;
    IF referenced AND (TG_OP = 'DELETE' OR
       OLD.workspace_id IS DISTINCT FROM NEW.workspace_id OR
       OLD.time_zone IS DISTINCT FROM NEW.time_zone OR
       OLD.weekly_hours IS DISTINCT FROM NEW.weekly_hours) THEN
      RAISE EXCEPTION 'used service calendar settings are immutable';
    END IF;
  ELSE
    IF TG_OP = 'UPDATE' THEN
      PERFORM 1 FROM service_calendars
      WHERE id IN (OLD.service_calendar_id, NEW.service_calendar_id)
      ORDER BY id FOR UPDATE;
      SELECT EXISTS (
        SELECT 1 FROM case_slas
        JOIN sla_policies ON sla_policies.id = case_slas.sla_policy_id
        WHERE sla_policies.service_calendar_id IN (OLD.service_calendar_id, NEW.service_calendar_id)
      ) INTO referenced;
    ELSE
      calendar_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.service_calendar_id ELSE OLD.service_calendar_id END;
      PERFORM 1 FROM service_calendars WHERE id = calendar_id FOR UPDATE;
      SELECT EXISTS (
        SELECT 1 FROM case_slas
        JOIN sla_policies ON sla_policies.id = case_slas.sla_policy_id
        WHERE sla_policies.service_calendar_id = calendar_id
      ) INTO referenced;
    END IF;
    IF referenced THEN
      RAISE EXCEPTION 'holidays on a used service calendar are immutable';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_account_health_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_account_health_snapshot() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'account health records are append only';
END;
$$;


--
-- Name: protect_agent_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_agent_profile() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE old_number integer; new_number integer;
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND
     ROW(OLD.id, OLD.workspace_id, OLD.crew_template_id, OLD.role_key, OLD.name, OLD.created_at)
     IS NOT DISTINCT FROM
     ROW(NEW.id, NEW.workspace_id, NEW.crew_template_id, NEW.role_key, NEW.name, NEW.created_at) AND
     OLD.current_version_id IS DISTINCT FROM NEW.current_version_id THEN
    SELECT version_number INTO old_number FROM agent_profile_versions WHERE id = OLD.current_version_id;
    SELECT version_number INTO new_number FROM agent_profile_versions WHERE id = NEW.current_version_id;
    IF NEW.current_version_id IS NOT NULL AND (OLD.current_version_id IS NULL OR new_number > old_number) THEN
      RETURN NEW;
    END IF;
  END IF;
  RAISE EXCEPTION 'agent profile identity and history are durable';
END;
$$;


--
-- Name: protect_agent_profile_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_agent_profile_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'agent profile versions are append only';
END;
$$;


--
-- Name: protect_attachment_join(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_attachment_join() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'attachment history is append only';
END;
$$;


--
-- Name: protect_crew_artifact(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_crew_artifact() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'crew artifacts are append only';
END;
$$;


--
-- Name: protect_crew_task(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_crew_task() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE old_sequence integer; event_row crew_task_events%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP <> 'UPDATE' OR
     ROW(OLD.id, OLD.workspace_id, OLD.task_key, OLD.scope_kind, OLD.support_case_id, OLD.account_id,
         OLD.crew_template_id, OLD.owner_membership_id, OLD.owner_user_id, OLD.title,
         OLD.input_context, OLD.expected_output, OLD.created_at)
       IS DISTINCT FROM
     ROW(NEW.id, NEW.workspace_id, NEW.task_key, NEW.scope_kind, NEW.support_case_id, NEW.account_id,
         NEW.crew_template_id, NEW.owner_membership_id, NEW.owner_user_id, NEW.title,
         NEW.input_context, NEW.expected_output, NEW.created_at) OR
     NEW.current_event_id IS NOT DISTINCT FROM OLD.current_event_id THEN
    RAISE EXCEPTION 'crew task identity and history are durable';
  END IF;
  SELECT * INTO event_row FROM crew_task_events WHERE id = NEW.current_event_id FOR UPDATE;
  SELECT sequence_number INTO old_sequence FROM crew_task_events WHERE id = OLD.current_event_id;
  IF event_row.id IS NULL OR event_row.workspace_id <> NEW.workspace_id OR event_row.crew_task_id <> NEW.id OR
     event_row.sequence_number <> COALESCE(old_sequence, 0) + 1 OR
     event_row.from_status IS DISTINCT FROM
       (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.status END) OR
     event_row.to_status IS DISTINCT FROM NEW.status OR
     event_row.from_agent_profile_id IS DISTINCT FROM
       (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.assigned_agent_profile_id END) OR
     event_row.to_agent_profile_id IS DISTINCT FROM NEW.assigned_agent_profile_id THEN
    RAISE EXCEPTION 'crew task update must advance its matching event';
  END IF;
  IF event_row.from_agent_profile_version_id IS DISTINCT FROM
       (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.assigned_agent_profile_version_id END) OR
     event_row.to_agent_profile_version_id IS DISTINCT FROM NEW.assigned_agent_profile_version_id OR
     NOT (CASE event_row.event_kind
       WHEN 'created' THEN OLD.current_event_id IS NULL AND event_row.from_status IS NULL
         AND event_row.body IS NULL AND event_row.evidence_kind IS NULL
         AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
       WHEN 'status_changed' THEN OLD.status <> NEW.status AND OLD.assigned_agent_profile_id = NEW.assigned_agent_profile_id
         AND event_row.evidence_kind IS NULL AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
       WHEN 'handoff' THEN OLD.status = NEW.status AND OLD.assigned_agent_profile_id <> NEW.assigned_agent_profile_id
         AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NULL
         AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
       WHEN 'comment' THEN OLD.status = NEW.status AND OLD.assigned_agent_profile_id = NEW.assigned_agent_profile_id
         AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NULL
         AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
       WHEN 'evidence_added' THEN OLD.status = NEW.status AND OLD.assigned_agent_profile_id = NEW.assigned_agent_profile_id
         AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NOT NULL AND event_row.evidence_locator IS NOT NULL
         AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
       WHEN 'review_requested' THEN OLD.status <> NEW.status AND NEW.status = 'review_requested'
         AND event_row.body IS NOT NULL AND event_row.evidence_kind IS NULL
         AND event_row.review_outcome IS NULL AND event_row.outcome_kind IS NULL
       WHEN 'review_resolved' THEN OLD.status = 'review_requested' AND NEW.status = 'in_progress'
         AND event_row.review_outcome = 'changes_requested' AND event_row.body IS NOT NULL
         AND event_row.evidence_kind IS NULL AND event_row.outcome_kind IS NULL
       WHEN 'outcome_recorded' THEN NEW.status IN ('completed', 'failed', 'canceled')
         AND event_row.outcome_kind = NEW.status AND event_row.body IS NOT NULL
         AND event_row.evidence_kind IS NULL AND (
           (NEW.status = 'completed' AND OLD.status = 'review_requested' AND event_row.review_outcome = 'approved') OR
           (NEW.status IN ('failed', 'canceled') AND event_row.review_outcome IS NULL)
         )
       ELSE false
     END) THEN
    RAISE EXCEPTION 'crew task event does not match its recorded change';
  END IF;
  IF OLD.current_event_id IS NOT NULL AND OLD.status <> NEW.status AND NOT (
    (OLD.status = 'pending' AND NEW.status IN ('ready', 'blocked', 'canceled')) OR
    (OLD.status = 'ready' AND NEW.status IN ('in_progress', 'blocked', 'canceled')) OR
    (OLD.status = 'in_progress' AND NEW.status IN ('blocked', 'review_requested', 'completed', 'failed', 'canceled')) OR
    (OLD.status = 'blocked' AND NEW.status IN ('ready', 'in_progress', 'failed', 'canceled')) OR
    (OLD.status = 'review_requested' AND NEW.status IN ('in_progress', 'completed', 'failed')) OR
    (OLD.status = 'failed' AND NEW.status IN ('ready', 'canceled'))
  ) THEN
    RAISE EXCEPTION 'invalid crew task transition';
  END IF;
  IF NEW.status IN ('ready', 'in_progress', 'review_requested', 'completed') AND EXISTS (
    SELECT 1 FROM crew_task_dependencies dependency
    JOIN crew_tasks prerequisite ON prerequisite.id = dependency.depends_on_task_id
    WHERE dependency.crew_task_id = NEW.id AND prerequisite.status <> 'completed'
  ) THEN
    RAISE EXCEPTION 'crew task dependencies are incomplete';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_crew_task_dependency(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_crew_task_dependency() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'crew task dependencies are append only';
END;
$$;


--
-- Name: protect_crew_task_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_crew_task_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'crew task events are append only';
END;
$$;


--
-- Name: protect_crew_template(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_crew_template() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'crew template identity is durable';
END;
$$;


--
-- Name: protect_customer_success_intervention(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_customer_success_intervention() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: protect_customer_success_outcome_review(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_customer_success_outcome_review() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'customer success outcome reviews cannot be truncated';
  END IF;
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'customer success outcome reviews are append only';
END;
$$;


--
-- Name: protect_execution_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_execution_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'execution events are append only';
END;
$$;


--
-- Name: protect_execution_memory_selection(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_execution_memory_selection() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'execution memory selections are append only';
END;
$$;


--
-- Name: protect_execution_personal_account(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_execution_personal_account() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE account personal_provider_accounts;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF (OLD.requested_by_membership_id, OLD.selected_personal_account_key) IS DISTINCT FROM (NEW.requested_by_membership_id, NEW.selected_personal_account_key) THEN
      RAISE EXCEPTION 'execution requester and personal account are immutable';
    END IF;
  ELSE
    SELECT a.* INTO account FROM runtime_installations r JOIN personal_provider_accounts a ON a.id = r.personal_provider_account_id WHERE r.id = NEW.runtime_installation_id;
    IF account.id IS NOT NULL THEN
      IF NEW.selected_personal_account_key IS DISTINCT FROM account.account_key OR NEW.requested_by_membership_id IS DISTINCT FROM account.membership_id OR NEW.workspace_id <> account.workspace_id THEN
        RAISE EXCEPTION 'execution personal account does not match requester and runtime';
      END IF;
    ELSIF NEW.selected_personal_account_key IS NOT NULL THEN
      RAISE EXCEPTION 'shared execution cannot claim a personal account';
    END IF;
  END IF;
  RETURN NEW;
END; $$;


--
-- Name: protect_execution_routing_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_execution_routing_snapshot() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF ROW(OLD.runtime_installation_id, OLD.selected_runtime_detection_key, OLD.selected_adapter_key,
         OLD.selected_runtime_profile_key, OLD.selected_runtime_configuration_fingerprint,
         OLD.selected_effective_model, OLD.selected_execution_mode, OLD.selected_isolation_policy,
         OLD.runtime_selection_reason, OLD.runtime_selection_detail, OLD.disclosed_data_classes,
         OLD.max_input_units, OLD.max_output_units)
     IS DISTINCT FROM
     ROW(NEW.runtime_installation_id, NEW.selected_runtime_detection_key, NEW.selected_adapter_key,
         NEW.selected_runtime_profile_key, NEW.selected_runtime_configuration_fingerprint,
         NEW.selected_effective_model, NEW.selected_execution_mode, NEW.selected_isolation_policy,
         NEW.runtime_selection_reason, NEW.runtime_selection_detail, NEW.disclosed_data_classes,
         NEW.max_input_units, NEW.max_output_units) THEN
    RAISE EXCEPTION 'execution routing snapshot is durable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_execution_run(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_execution_run() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE event_row execution_events%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP <> 'UPDATE' OR
     ROW(OLD.id, OLD.workspace_id, OLD.crew_task_id, OLD.agent_profile_id,
         OLD.agent_profile_version_id, OLD.run_key, OLD.request_key, OLD.attempt_number,
         OLD.runtime_profile_key, OLD.created_at)
       IS DISTINCT FROM
     ROW(NEW.id, NEW.workspace_id, NEW.crew_task_id, NEW.agent_profile_id,
         NEW.agent_profile_version_id, NEW.run_key, NEW.request_key, NEW.attempt_number,
         NEW.runtime_profile_key, NEW.created_at) THEN
    RAISE EXCEPTION 'execution run identity is durable';
  END IF;

  IF NEW.current_sequence = OLD.current_sequence AND NEW.current_event_id IS NOT DISTINCT FROM OLD.current_event_id THEN
    IF OLD.status <> 'admitting' OR NEW.status <> OLD.status OR
       ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
           OLD.admitted_at, OLD.started_at, OLD.finished_at)
         IS DISTINCT FROM
       ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
           NEW.admitted_at, NEW.started_at, NEW.finished_at) OR
       NEW.admission_attempt_count < OLD.admission_attempt_count OR
       NEW.admission_attempt_count > OLD.admission_attempt_count + 1 THEN
      RAISE EXCEPTION 'execution admission update is invalid';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.current_sequence <> OLD.current_sequence + 1 OR NEW.current_event_id IS NULL THEN
    RAISE EXCEPTION 'execution run events must be ordered';
  END IF;
  SELECT * INTO event_row FROM execution_events WHERE id = NEW.current_event_id FOR UPDATE;
  IF event_row.id IS NULL OR event_row.workspace_id <> NEW.workspace_id OR
     event_row.execution_run_id <> NEW.id OR event_row.sequence_number <> NEW.current_sequence THEN
    RAISE EXCEPTION 'execution run event does not match';
  END IF;
  IF NEW.admission_attempt_count <> OLD.admission_attempt_count OR
     NEW.admission_attempted_at IS DISTINCT FROM OLD.admission_attempted_at OR
     (event_row.event_type <> 'run.admitted' AND NEW.last_admission_error IS DISTINCT FROM OLD.last_admission_error) OR
     (event_row.event_type = 'run.admitted' AND NEW.last_admission_error IS NOT NULL) OR
     (OLD.current_event_id IS NOT NULL AND event_row.occurred_at <
       (SELECT occurred_at FROM execution_events WHERE id = OLD.current_event_id)) THEN
    RAISE EXCEPTION 'execution event changed admission history or time order';
  END IF;
  IF (CASE event_row.event_type
    WHEN 'run.admitted' THEN OLD.status = 'admitting' AND NEW.status = 'admitted'
      AND NEW.admitted_at = event_row.occurred_at AND OLD.admitted_at IS NULL
      AND event_row.data->>'workspace_key' = (SELECT runner_key::text FROM workspaces WHERE id = NEW.workspace_id)
      AND event_row.data->>'task_key' = (SELECT task_key::text FROM crew_tasks WHERE id = NEW.crew_task_id)
      AND (event_row.data->>'attempt')::integer = NEW.attempt_number
      AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
              NEW.started_at, NEW.finished_at)
        IS NOT DISTINCT FROM
          ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
              OLD.started_at, OLD.finished_at)
    WHEN 'run.started' THEN OLD.status = 'admitted' AND NEW.status = 'running'
      AND NEW.started_at = event_row.occurred_at AND OLD.started_at IS NULL
      AND octet_length(event_row.data->>'adapter') BETWEEN 1 AND 64
      AND octet_length(event_row.data->>'scenario') BETWEEN 1 AND 100
      AND (event_row.data->>'attempt')::integer = NEW.attempt_number
      AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
              NEW.admitted_at, NEW.finished_at)
        IS NOT DISTINCT FROM
          ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
              OLD.admitted_at, OLD.finished_at)
    WHEN 'tool.completed' THEN OLD.status = 'running' AND NEW.status = OLD.status
      AND octet_length(event_row.data->>'tool') BETWEEN 1 AND 64
      AND octet_length(event_row.data->>'result') BETWEEN 1 AND 100
      AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
              NEW.admitted_at, NEW.started_at, NEW.finished_at)
        IS NOT DISTINCT FROM
          ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
              OLD.admitted_at, OLD.started_at, OLD.finished_at)
    WHEN 'output.produced' THEN OLD.status = 'running' AND NEW.status = OLD.status
      AND NEW.output = event_row.data->>'text'
      AND ROW(NEW.input_units, NEW.output_units, NEW.failure_code, NEW.retryable,
              NEW.admitted_at, NEW.started_at, NEW.finished_at)
        IS NOT DISTINCT FROM
          ROW(OLD.input_units, OLD.output_units, OLD.failure_code, OLD.retryable,
              OLD.admitted_at, OLD.started_at, OLD.finished_at)
    WHEN 'usage.observed' THEN OLD.status = 'running' AND NEW.status = OLD.status
      AND NEW.input_units = OLD.input_units + (event_row.data->>'input_units')::bigint
      AND NEW.output_units = OLD.output_units + (event_row.data->>'output_units')::bigint
      AND ROW(NEW.output, NEW.failure_code, NEW.retryable, NEW.admitted_at, NEW.started_at, NEW.finished_at)
        IS NOT DISTINCT FROM
          ROW(OLD.output, OLD.failure_code, OLD.retryable, OLD.admitted_at, OLD.started_at, OLD.finished_at)
    WHEN 'run.completed' THEN OLD.status = 'running' AND NEW.status = 'completed'
      AND NEW.finished_at = event_row.occurred_at AND event_row.data->>'outcome' = 'completed'
      AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
              NEW.admitted_at, NEW.started_at)
        IS NOT DISTINCT FROM
          ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
              OLD.admitted_at, OLD.started_at)
    WHEN 'run.failed' THEN OLD.status = 'running' AND NEW.status = 'failed'
      AND NEW.failure_code = event_row.data->>'code'
      AND NEW.retryable = (event_row.data->>'retryable')::boolean AND NEW.finished_at = event_row.occurred_at
      AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
        IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
    WHEN 'run.timed_out' THEN OLD.status = 'running' AND NEW.status = 'timed_out'
      AND NEW.failure_code = 'timed_out' AND NEW.retryable = false AND NEW.finished_at = event_row.occurred_at
      AND octet_length(event_row.data->>'reason') BETWEEN 1 AND 500
      AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
        IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
    WHEN 'run.canceled' THEN OLD.status = 'running' AND NEW.status = 'canceled'
      AND NEW.failure_code = 'canceled' AND NEW.retryable = false AND NEW.finished_at = event_row.occurred_at
      AND octet_length(event_row.data->>'reason') BETWEEN 1 AND 500
      AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
        IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
    WHEN 'run.policy_denied' THEN OLD.status IN ('admitted', 'running') AND NEW.status = 'policy_denied'
      AND NEW.failure_code = event_row.data->>'code' AND NEW.retryable = false AND NEW.finished_at = event_row.occurred_at
      AND octet_length(event_row.data->>'code') BETWEEN 1 AND 100
      AND octet_length(event_row.data->>'tool') BETWEEN 1 AND 64
      AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
        IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
    ELSE false
  END) IS NOT TRUE THEN
    RAISE EXCEPTION 'invalid execution run transition';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_execution_run_context(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_execution_run_context() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.input_context IS DISTINCT FROM OLD.input_context OR
     NEW.input_artifact_id IS DISTINCT FROM OLD.input_artifact_id THEN
    RAISE EXCEPTION 'execution run context is immutable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_execution_run_memory_context(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_execution_run_memory_context() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF ROW(OLD.memory_context_status, OLD.memory_context_detail)
    IS DISTINCT FROM ROW(NEW.memory_context_status, NEW.memory_context_detail) THEN
    RAISE EXCEPTION 'execution run memory context is immutable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_execution_usage_rate(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_execution_usage_rate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.usage_rate_version_id IS DISTINCT FROM NEW.usage_rate_version_id THEN
    RAISE EXCEPTION 'execution run usage rate is immutable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_governed_policy_preview(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_governed_policy_preview() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'governed policy previews are append only';
END;
$$;


--
-- Name: protect_governed_policy_proposal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_governed_policy_proposal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'governed policy proposals are append only';
END;
$$;


--
-- Name: protect_governed_policy_publication(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_governed_policy_publication() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'governed policy publications are append only';
END;
$$;


--
-- Name: protect_governed_policy_subject(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_governed_policy_subject() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'governed policy subjects are append only';
END;
$$;


--
-- Name: protect_health_scorecard_record(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_health_scorecard_record() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_TABLE_NAME = 'health_scorecards' AND TG_OP = 'UPDATE' AND
     ROW(OLD.id, OLD.workspace_id, OLD.name, OLD.created_at)
       IS NOT DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.name, NEW.created_at) AND
     OLD.current_version_id IS DISTINCT FROM NEW.current_version_id THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'health scorecard records are durable';
END;
$$;


--
-- Name: protect_intercom_outbound_delivery(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_intercom_outbound_delivery() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND
     ROW(OLD.id, OLD.workspace_id, OLD.intercom_draft_id, OLD.intercom_connection_id,
         OLD.intercom_conversation_link_id, OLD.conversation_id, OLD.actor_membership_id,
         OLD.actor_user_id, OLD.idempotency_key, OLD.remote_conversation_id,
         OLD.source_part_id, OLD.admin_id, OLD.body, OLD.source_crew_artifact_id, OLD.generated_body_digest, OLD.generated_contract_result_state, OLD.human_edited_by_membership_id, OLD.human_edited_by_user_id, OLD.human_edited_at, OLD.started_at, OLD.created_at)
     IS NOT DISTINCT FROM
     ROW(NEW.id, NEW.workspace_id, NEW.intercom_draft_id, NEW.intercom_connection_id,
         NEW.intercom_conversation_link_id, NEW.conversation_id, NEW.actor_membership_id,
         NEW.actor_user_id, NEW.idempotency_key, NEW.remote_conversation_id,
         NEW.source_part_id, NEW.admin_id, NEW.body, NEW.source_crew_artifact_id, NEW.generated_body_digest, NEW.generated_contract_result_state, NEW.human_edited_by_membership_id, NEW.human_edited_by_user_id, NEW.human_edited_at, NEW.started_at, NEW.created_at) AND
     ((OLD.status = 'sending' AND NEW.status IN ('sent', 'failed', 'unknown')) OR
      (OLD.status = 'unknown' AND NEW.status IN ('sent', 'failed'))) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Intercom outbound delivery records are durable';
END;
$$;


--
-- Name: protect_knowledge_origin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_knowledge_origin() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.intercom_connection_id IS DISTINCT FROM NEW.intercom_connection_id THEN
    RAISE EXCEPTION 'knowledge origin is immutable';
  END IF;
  RETURN NEW;
END; $$;


--
-- Name: protect_knowledge_source(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_knowledge_source() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_number integer;
  new_number integer;
BEGIN
  IF TG_OP = 'UPDATE' AND
     ROW(OLD.id, OLD.workspace_id, OLD.source_kind, OLD.source_key, OLD.title,
         OLD.canonical_url, OLD.external_id, OLD.created_at)
     IS NOT DISTINCT FROM
     ROW(NEW.id, NEW.workspace_id, NEW.source_kind, NEW.source_key, NEW.title,
         NEW.canonical_url, NEW.external_id, NEW.created_at) THEN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NULL AND
       ROW(OLD.deleted_by_membership_id, OLD.deleted_by_user_id)
       IS NOT DISTINCT FROM
       ROW(NEW.deleted_by_membership_id, NEW.deleted_by_user_id) AND
       OLD.current_version_id IS DISTINCT FROM NEW.current_version_id THEN
      SELECT version_number INTO old_number FROM knowledge_source_versions WHERE id = OLD.current_version_id;
      SELECT version_number INTO new_number FROM knowledge_source_versions WHERE id = NEW.current_version_id;
      IF NEW.current_version_id IS NOT NULL AND (OLD.current_version_id IS NULL OR new_number > old_number) THEN
        RETURN NEW;
      END IF;
    ELSIF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND
          NEW.deleted_by_membership_id IS NOT NULL AND NEW.deleted_by_user_id IS NOT NULL AND
          OLD.current_version_id IS NOT DISTINCT FROM NEW.current_version_id THEN
      RETURN NEW;
    END IF;
  END IF;
  RAISE EXCEPTION 'knowledge source identity and history are durable';
END;
$$;


--
-- Name: protect_knowledge_source_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_knowledge_source_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'knowledge source versions are append only';
END;
$$;


--
-- Name: protect_memory_correction_proposal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_memory_correction_proposal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'memory correction proposals cannot be truncated';
  END IF;
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP = 'DELETE' OR ROW(OLD.id, OLD.workspace_id, OLD.memory_record_id,
    OLD.proposed_by_membership_id, OLD.proposed_by_user_id, OLD.proposal_key, OLD.content,
    OLD.content_digest, OLD.confidence, OLD.retention_policy, OLD.retention_until, OLD.created_at)
    IS DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.memory_record_id,
    NEW.proposed_by_membership_id, NEW.proposed_by_user_id, NEW.proposal_key, NEW.content,
    NEW.content_digest, NEW.confidence, NEW.retention_policy, NEW.retention_until, NEW.created_at) THEN
    RAISE EXCEPTION 'memory correction proposal identity is immutable';
  END IF;
  IF OLD.status <> 'proposed' OR NEW.status NOT IN ('accepted', 'rejected') THEN
    RAISE EXCEPTION 'memory correction review is terminal';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_memory_index_entry(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_memory_index_entry() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'memory index entries cannot be truncated';
  END IF;
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP = 'DELETE' OR ROW(OLD.id, OLD.workspace_id, OLD.memory_record_id, OLD.created_at)
    IS DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.memory_record_id, NEW.created_at) THEN
    RAISE EXCEPTION 'memory index entry identity is immutable';
  END IF;
  IF NOT ((OLD.status IN ('pending', 'queued', 'failed', 'unknown', 'indexing') AND NEW.status = 'indexing') OR
          (OLD.status = 'indexing' AND NEW.status IN ('queued', 'indexed', 'failed', 'unknown'))) THEN
    RAISE EXCEPTION 'memory index entry transition is invalid';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_memory_proposal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_memory_proposal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'memory proposals cannot be truncated';
  END IF;
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'memory proposals cannot be deleted';
  END IF;
  IF ROW(OLD.id, OLD.workspace_id, OLD.source_crew_artifact_id, OLD.source_agent_profile_id,
    OLD.account_id, OLD.contact_id, OLD.support_case_id, OLD.proposal_key, OLD.memory_type,
    OLD.scope_kind, OLD.topic, OLD.content, OLD.content_digest, OLD.confidence, OLD.created_at)
    IS DISTINCT FROM
    ROW(NEW.id, NEW.workspace_id, NEW.source_crew_artifact_id, NEW.source_agent_profile_id,
    NEW.account_id, NEW.contact_id, NEW.support_case_id, NEW.proposal_key, NEW.memory_type,
    NEW.scope_kind, NEW.topic, NEW.content, NEW.content_digest, NEW.confidence, NEW.created_at) THEN
    RAISE EXCEPTION 'memory proposal identity is immutable';
  END IF;
  IF OLD.status <> 'proposed' OR NEW.status NOT IN ('accepted', 'rejected') THEN
    RAISE EXCEPTION 'memory proposal review is terminal';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_memory_record(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_memory_record() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  prior memory_records%ROWTYPE;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.supersedes_memory_record_id IS NOT NULL THEN
    SELECT * INTO prior
    FROM memory_records
    WHERE id = NEW.supersedes_memory_record_id AND workspace_id = NEW.workspace_id
    FOR SHARE;

    IF prior.id IS NULL OR
       ROW(prior.memory_type, prior.scope_kind, prior.topic, prior.organization_id,
           prior.account_id, prior.contact_id, prior.support_case_id, prior.crew_template_id,
           prior.agent_profile_id, prior.user_id)
       IS DISTINCT FROM
       ROW(NEW.memory_type, NEW.scope_kind, NEW.topic, NEW.organization_id,
           NEW.account_id, NEW.contact_id, NEW.support_case_id, NEW.crew_template_id,
           NEW.agent_profile_id, NEW.user_id) THEN
      RAISE EXCEPTION 'superseding memory must keep its workspace, type, topic, and scope';
    END IF;

    IF (CASE NEW.authority WHEN 'human_correction' THEN 3 WHEN 'source_record' THEN 2 ELSE 1 END) <
       (CASE prior.authority WHEN 'human_correction' THEN 3 WHEN 'source_record' THEN 2 ELSE 1 END) THEN
      RAISE EXCEPTION 'superseding memory cannot lower authority';
    END IF;
  END IF;

  IF TG_OP = 'INSERT' AND NEW.authority = 'human_correction' AND NOT EXISTS (
    SELECT 1 FROM memberships
    WHERE id = NEW.source_membership_id AND workspace_id = NEW.workspace_id AND
          user_id = NEW.source_user_id AND role IN ('owner', 'admin', 'manager')
  ) THEN
    RAISE EXCEPTION 'human correction requires an authorized workspace member';
  END IF;

  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'memory records are append only';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_memory_tombstone(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_memory_tombstone() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'memory tombstones cannot be truncated';
  END IF;
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP = 'DELETE' OR ROW(OLD.id, OLD.workspace_id, OLD.memory_record_id,
    OLD.deleted_by_membership_id, OLD.deleted_by_user_id, OLD.reason, OLD.created_at)
    IS DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.memory_record_id,
    NEW.deleted_by_membership_id, NEW.deleted_by_user_id, NEW.reason, NEW.created_at) THEN
    RAISE EXCEPTION 'memory tombstone identity is immutable';
  END IF;
  IF NOT ((OLD.index_status IN ('pending', 'failed', 'unknown') AND NEW.index_status = 'removing') OR
          (OLD.index_status = 'removing' AND NEW.index_status IN ('removed', 'failed', 'unknown'))) THEN
    RAISE EXCEPTION 'memory tombstone transition is invalid';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_notion_knowledge_origin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_notion_knowledge_origin() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.notion_knowledge_connection_id IS DISTINCT FROM NEW.notion_knowledge_connection_id THEN
    RAISE EXCEPTION 'knowledge origin is immutable';
  END IF;
  RETURN NEW;
END; $$;


--
-- Name: protect_operational_check(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_operational_check() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'operational checks cannot be truncated';
  END IF;
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'operational checks are append only';
END;
$$;


--
-- Name: protect_outbound_email_delivery(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_outbound_email_delivery() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND
     ROW(OLD.id, OLD.workspace_id, OLD.email_draft_id, OLD.shared_email_inbox_id,
         OLD.email_thread_id, OLD.conversation_id, OLD.actor_membership_id,
         OLD.actor_user_id, OLD.idempotency_key, OLD.message_id,
         OLD.in_reply_to_message_id, OLD.from_address, OLD.to_address,
         OLD.subject, OLD.body, OLD.source_crew_artifact_id, OLD.generated_body_digest, OLD.generated_contract_result_state, OLD.human_edited_by_membership_id, OLD.human_edited_by_user_id, OLD.human_edited_at, OLD.started_at, OLD.created_at)
     IS NOT DISTINCT FROM
     ROW(NEW.id, NEW.workspace_id, NEW.email_draft_id, NEW.shared_email_inbox_id,
         NEW.email_thread_id, NEW.conversation_id, NEW.actor_membership_id,
         NEW.actor_user_id, NEW.idempotency_key, NEW.message_id,
         NEW.in_reply_to_message_id, NEW.from_address, NEW.to_address,
         NEW.subject, NEW.body, NEW.source_crew_artifact_id, NEW.generated_body_digest, NEW.generated_contract_result_state, NEW.human_edited_by_membership_id, NEW.human_edited_by_user_id, NEW.human_edited_at, NEW.started_at, NEW.created_at) AND
     ((OLD.status = 'sending' AND NEW.status IN ('sent', 'failed', 'unknown')) OR
      (OLD.status = 'unknown' AND NEW.status IN ('sent', 'failed'))) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'outbound email delivery records are durable';
END;
$$;


--
-- Name: protect_outbound_webhook_delivery(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_outbound_webhook_delivery() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: protect_personal_provider_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_personal_provider_identity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (OLD.workspace_id, OLD.membership_id, OLD.account_key) IS DISTINCT FROM (NEW.workspace_id, NEW.membership_id, NEW.account_key) THEN
    RAISE EXCEPTION 'personal provider account identity is immutable';
  END IF;
  RETURN NEW;
END; $$;


--
-- Name: protect_public_web_extraction(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_public_web_extraction() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
    RAISE EXCEPTION 'public web extraction is append-only';
  ELSIF ROW(OLD.id, OLD.workspace_id, OLD.public_web_search_result_id, OLD.request_key, OLD.source_url,
    OLD.requested_by_membership_id, OLD.requested_by_user_id, OLD.created_at)
    IS DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.public_web_search_result_id, NEW.request_key, NEW.source_url,
    NEW.requested_by_membership_id, NEW.requested_by_user_id, NEW.created_at) THEN
    RAISE EXCEPTION 'public web extraction identity is immutable';
  END IF;
  IF OLD.status <> 'extracting' OR NEW.status NOT IN ('completed', 'failed') THEN
    RAISE EXCEPTION 'public web extraction result is terminal';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_public_web_search(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_public_web_search() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
    RAISE EXCEPTION 'public web search identity is immutable';
  ELSIF ROW(OLD.id, OLD.workspace_id, OLD.crew_task_id, OLD.request_key, OLD.query,
    OLD.requested_by_membership_id, OLD.requested_by_user_id, OLD.created_at)
    IS DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.crew_task_id, NEW.request_key, NEW.query,
    NEW.requested_by_membership_id, NEW.requested_by_user_id, NEW.created_at) THEN
    RAISE EXCEPTION 'public web search identity is immutable';
  END IF;
  IF OLD.status <> 'searching' OR NEW.status NOT IN ('completed', 'failed') THEN
    RAISE EXCEPTION 'public web search result is terminal';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_public_web_search_result(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_public_web_search_result() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM 1 FROM public_web_searches
    WHERE id = NEW.public_web_search_id AND workspace_id = NEW.workspace_id AND status = 'completed';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'public web search results require a completed search';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'public web search results are append-only';
END;
$$;


--
-- Name: protect_public_web_search_usage_rate(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_public_web_search_usage_rate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.usage_rate_version_id IS DISTINCT FROM NEW.usage_rate_version_id THEN
    RAISE EXCEPTION 'public web search usage rate is immutable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_resolution_contract_family(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_resolution_contract_family() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND
     ROW(OLD.id, OLD.workspace_id, OLD.family_key, OLD.created_at)
       IS NOT DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.family_key, NEW.created_at) AND
     OLD.current_version_id IS DISTINCT FROM NEW.current_version_id THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'resolution contract families are durable';
END;
$$;


--
-- Name: protect_resolution_contract_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_resolution_contract_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'resolution contract versions are append only';
END;
$$;


--
-- Name: protect_search_provider_selection(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_search_provider_selection() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.requested_provider_key IS DISTINCT FROM OLD.requested_provider_key THEN
    RAISE EXCEPTION 'search provider selection is immutable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_stored_attachment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_stored_attachment() RETURNS trigger
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


--
-- Name: protect_stored_attachment_file(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_stored_attachment_file() RETURNS trigger
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


--
-- Name: protect_usage_cost_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_usage_cost_snapshot() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'usage cost snapshots are append only';
END;
$$;


--
-- Name: protect_usage_rate_setting(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_usage_rate_setting() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP <> 'UPDATE' OR
     ROW(OLD.id, OLD.workspace_id, OLD.created_at) IS DISTINCT FROM
     ROW(NEW.id, NEW.workspace_id, NEW.created_at) THEN
    RAISE EXCEPTION 'usage rate setting identity is durable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_usage_rate_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_usage_rate_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'usage rate versions are append only';
END;
$$;


--
-- Name: protect_workspace_runner_key(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_workspace_runner_key() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.runner_key IS DISTINCT FROM NEW.runner_key THEN
    RAISE EXCEPTION 'workspace runner key is durable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: protect_workspace_tombstone(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_workspace_tombstone() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'workspace tombstones cannot be truncated';
  END IF;
  RAISE EXCEPTION 'workspace tombstones are immutable';
END;
$$;


--
-- Name: require_current_agent_profile_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.require_current_agent_profile_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM agent_profiles
    WHERE id = NEW.id AND workspace_id = NEW.workspace_id AND current_version_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'agent profile must have a current version';
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: require_current_crew_task_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.require_current_crew_task_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM crew_tasks
    WHERE id = NEW.id AND workspace_id = NEW.workspace_id AND current_event_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'crew task must have a current event';
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: require_current_knowledge_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.require_current_knowledge_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM knowledge_sources
    WHERE id = NEW.id
      AND workspace_id = NEW.workspace_id
      AND current_version_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'knowledge source must have a current version';
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: require_linked_crew_task_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.require_linked_crew_task_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE current_sequence integer;
BEGIN
  SELECT event.sequence_number INTO current_sequence
  FROM crew_tasks task JOIN crew_task_events event ON event.id = task.current_event_id
  WHERE task.id = NEW.crew_task_id AND task.workspace_id = NEW.workspace_id;
  IF current_sequence IS NULL OR current_sequence < NEW.sequence_number THEN
    RAISE EXCEPTION 'crew task event must advance its task';
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: require_linked_execution_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.require_linked_execution_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM execution_runs
    WHERE id = NEW.execution_run_id AND workspace_id = NEW.workspace_id
      AND current_event_id = NEW.id AND current_sequence = NEW.sequence_number
  ) THEN
    RAISE EXCEPTION 'execution event must advance its run';
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: resolution_grounding_valid(jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolution_grounding_valid(required_facts jsonb, material_claims jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $_$
DECLARE
  claim jsonb;
  evidence jsonb;
  claim_key text;
  claim_keys text[] := ARRAY[]::text[];
  evidence_keys text[];
  required_fact jsonb;
BEGIN
  IF jsonb_typeof(required_facts) <> 'array' OR jsonb_typeof(material_claims) <> 'array' THEN
    RETURN FALSE;
  END IF;
  FOR claim IN SELECT value FROM jsonb_array_elements(material_claims)
  LOOP
    IF jsonb_typeof(claim) <> 'object' OR
       NOT claim ?& ARRAY['category','evidence','key','state','text'] OR
       claim - ARRAY['category','evidence','key','state','text'] <> '{}'::jsonb OR
       jsonb_typeof(claim->'key') <> 'string' OR
       jsonb_typeof(claim->'category') <> 'string' OR
       jsonb_typeof(claim->'state') <> 'string' OR
       jsonb_typeof(claim->'text') <> 'string' OR
       jsonb_typeof(claim->'evidence') <> 'array' OR
       jsonb_array_length(claim->'evidence') > 20 OR
       claim->>'key' !~ '^[a-z][a-z0-9_]{0,63}$' OR
       octet_length(btrim(claim->>'text')) NOT BETWEEN 1 AND 4000 OR
       claim->>'category' NOT IN ('customer_account_fact','product_technical_fact','policy_entitlement','promised_action_date') OR
       claim->>'state' NOT IN ('supported','uncertain','conflicted','refused') THEN
      RETURN FALSE;
    END IF;
    claim_key := claim->>'key';
    IF claim_key = ANY(claim_keys) THEN
      RETURN FALSE;
    END IF;
    claim_keys := array_append(claim_keys, claim_key);
    evidence_keys := ARRAY[]::text[];
    FOR evidence IN SELECT value FROM jsonb_array_elements(claim->'evidence')
    LOOP
      IF jsonb_typeof(evidence) <> 'object' OR
         NOT evidence ?& ARRAY['kind','locator','status','observed_at','valid_until','fresh_until'] OR
         evidence - ARRAY['kind','locator','status','observed_at','valid_until','fresh_until'] <> '{}'::jsonb OR
         jsonb_typeof(evidence->'kind') <> 'string' OR
         jsonb_typeof(evidence->'locator') <> 'string' OR
         jsonb_typeof(evidence->'status') <> 'string' OR
         octet_length(btrim(evidence->>'locator')) NOT BETWEEN 1 AND 2000 OR
         evidence->>'kind' NOT IN ('knowledge','conversation','case','account','health_signal','public_web','memory') OR
         evidence->>'status' NOT IN ('available','stale','expired','deleted','unavailable','conflicted','not_yet_valid','superseded') OR
         jsonb_typeof(evidence->'observed_at') NOT IN ('string','null') OR
         jsonb_typeof(evidence->'valid_until') NOT IN ('string','null') OR
         jsonb_typeof(evidence->'fresh_until') NOT IN ('string','null') THEN
        RETURN FALSE;
      END IF;
      IF ((evidence->>'kind') || ':' || (evidence->>'locator')) = ANY(evidence_keys) THEN
        RETURN FALSE;
      END IF;
      evidence_keys := array_append(evidence_keys, (evidence->>'kind') || ':' || (evidence->>'locator'));
    END LOOP;
    IF claim->>'state' <> 'refused' AND jsonb_array_length(claim->'evidence') = 0 THEN
      RETURN FALSE;
    END IF;
    IF claim->>'state' = 'supported' AND (
         jsonb_array_length(claim->'evidence') = 0 OR
         EXISTS (
           SELECT 1 FROM jsonb_array_elements(claim->'evidence') item
           WHERE item->>'status' <> 'available' OR
                 jsonb_typeof(item->'observed_at') <> 'string' OR
                 jsonb_typeof(item->'fresh_until') <> 'string'
         )
       ) THEN
      RETURN FALSE;
    END IF;
  END LOOP;
  FOR required_fact IN SELECT value FROM jsonb_array_elements(required_facts)
  LOOP
    IF jsonb_typeof(required_fact) <> 'string' OR
       (required_fact #>> '{}') !~ '^[a-z][a-z0-9_]{0,63}$' OR
       NOT ((required_fact #>> '{}') = ANY(claim_keys)) THEN
      RETURN FALSE;
    END IF;
  END LOOP;
  RETURN jsonb_array_length(required_facts) = cardinality(
    ARRAY(SELECT DISTINCT value #>> '{}' FROM jsonb_array_elements(required_facts))
  );
EXCEPTION WHEN OTHERS THEN
  RETURN FALSE;
END;
$_$;


--
-- Name: validate_agent_profile_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_agent_profile_identity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE kind text;
BEGIN
  SELECT crew_kind INTO kind FROM crew_templates
  WHERE id = NEW.crew_template_id AND workspace_id = NEW.workspace_id;
  IF (kind = 'support' AND NEW.role_key NOT IN (
        'support_coordinator', 'support_investigator', 'resolution_drafter', 'support_reviewer'
      )) OR
     (kind = 'customer_success' AND NEW.role_key NOT IN (
        'account_analyst', 'risk_investigator', 'success_strategist', 'success_reviewer'
      )) OR kind IS NULL THEN
    RAISE EXCEPTION 'agent role does not belong to its crew';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: validate_agent_profile_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_agent_profile_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE role text; maximum_tools jsonb;
BEGIN
  SELECT role_key INTO role FROM agent_profiles
  WHERE id = NEW.agent_profile_id AND workspace_id = NEW.workspace_id FOR UPDATE;
  maximum_tools := CASE role
    WHEN 'support_coordinator' THEN '["conversation_read", "case_read"]'::jsonb
    WHEN 'support_investigator' THEN '["conversation_read","case_read","knowledge_search","public_web_search","web_extract"]'::jsonb
    WHEN 'resolution_drafter' THEN '["conversation_read", "case_read", "knowledge_search", "draft_propose"]'::jsonb
    WHEN 'support_reviewer' THEN '["conversation_read", "case_read", "knowledge_search", "review_record"]'::jsonb
    WHEN 'account_analyst' THEN '["account_read", "conversation_read"]'::jsonb
    WHEN 'risk_investigator' THEN '["account_read","conversation_read","knowledge_search","public_web_search","web_extract"]'::jsonb
    WHEN 'success_strategist' THEN '["account_read", "knowledge_search", "note_propose"]'::jsonb
    WHEN 'success_reviewer' THEN '["account_read", "knowledge_search", "review_record"]'::jsonb
  END;
  IF role IS NULL OR NOT (NEW.allowed_tools <@ maximum_tools) OR
     NEW.allowed_tools <> (SELECT jsonb_agg(value ORDER BY value) FROM (
       SELECT DISTINCT value FROM jsonb_array_elements(NEW.allowed_tools)
     ) values) OR
     NEW.runtime_profile_key IN (SELECT jsonb_array_elements_text(NEW.fallback_profile_keys)) OR
     jsonb_array_length(NEW.fallback_profile_keys) <>
       (SELECT count(DISTINCT value) FROM jsonb_array_elements_text(NEW.fallback_profile_keys) values) THEN
    RAISE EXCEPTION 'agent profile exceeds its approved policy bounds';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: validate_crew_task_dependency(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_crew_task_dependency() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE task_scope record; dependency_scope record;
BEGIN
  SELECT scope_kind, support_case_id, account_id INTO task_scope
  FROM crew_tasks WHERE id = NEW.crew_task_id AND workspace_id = NEW.workspace_id FOR UPDATE;
  SELECT scope_kind, support_case_id, account_id INTO dependency_scope
  FROM crew_tasks WHERE id = NEW.depends_on_task_id AND workspace_id = NEW.workspace_id FOR UPDATE;
  IF task_scope IS NULL OR dependency_scope IS NULL OR
     ROW(task_scope.scope_kind, task_scope.support_case_id, task_scope.account_id)
       IS DISTINCT FROM
     ROW(dependency_scope.scope_kind, dependency_scope.support_case_id, dependency_scope.account_id) OR
     EXISTS (
       WITH RECURSIVE ancestors(id) AS (
         SELECT depends_on_task_id FROM crew_task_dependencies
         WHERE crew_task_id = NEW.depends_on_task_id
         UNION
         SELECT dependency.depends_on_task_id
         FROM crew_task_dependencies dependency JOIN ancestors ON dependency.crew_task_id = ancestors.id
       ) SELECT 1 FROM ancestors WHERE id = NEW.crew_task_id
     ) OR EXISTS (
       SELECT 1 FROM crew_tasks task
       JOIN crew_tasks prerequisite ON prerequisite.id = NEW.depends_on_task_id
       WHERE task.id = NEW.crew_task_id AND task.status <> 'pending' AND prerequisite.status <> 'completed'
     ) THEN
    RAISE EXCEPTION 'crew task dependency must share scope and cannot form a cycle';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: validate_governed_crew_task_projection(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_governed_crew_task_projection() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE event_row crew_task_events%ROWTYPE;
BEGIN
  IF TG_OP <> 'UPDATE' OR NEW.current_event_id IS NOT DISTINCT FROM OLD.current_event_id THEN
    RETURN NEW;
  END IF;
  SELECT * INTO event_row FROM crew_task_events WHERE id = NEW.current_event_id;
  IF event_row.from_governed_policy_publication_id IS DISTINCT FROM
       (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.governed_policy_publication_id END) OR
     event_row.to_governed_policy_publication_id IS DISTINCT FROM NEW.governed_policy_publication_id OR
     event_row.from_resolution_contract_version_id IS DISTINCT FROM
       (CASE WHEN OLD.current_event_id IS NULL THEN NULL ELSE OLD.resolution_contract_version_id END) OR
     event_row.to_resolution_contract_version_id IS DISTINCT FROM NEW.resolution_contract_version_id THEN
    RAISE EXCEPTION 'crew task governed policy projection must match its event';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: validate_governed_policy_publication(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_governed_policy_publication() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE policy governed_policy_proposals%ROWTYPE; prior governed_policy_publications%ROWTYPE;
BEGIN
  SELECT * INTO policy FROM governed_policy_proposals
    WHERE id = NEW.governed_policy_proposal_id AND workspace_id = NEW.workspace_id;
  IF NEW.supersedes_publication_id IS NOT NULL THEN
    SELECT * INTO prior FROM governed_policy_publications
      WHERE id = NEW.supersedes_publication_id AND workspace_id = NEW.workspace_id;
    IF prior.id IS NULL OR NOT EXISTS (
        SELECT 1 FROM governed_policy_proposals predecessor
        WHERE predecessor.id = prior.governed_policy_proposal_id
          AND predecessor.workspace_id = NEW.workspace_id
          AND predecessor.scope_kind = policy.scope_kind
          AND predecessor.resolution_contract_family_id = policy.resolution_contract_family_id
          AND predecessor.agent_profile_id = policy.agent_profile_id
      ) OR EXISTS (
        (SELECT subject_kind, support_case_id, account_id, agent_profile_id
          FROM governed_policy_subjects WHERE governed_policy_proposal_id = policy.id
         EXCEPT
         SELECT subject_kind, support_case_id, account_id, agent_profile_id
          FROM governed_policy_subjects WHERE governed_policy_proposal_id = prior.governed_policy_proposal_id)
        UNION ALL
        (SELECT subject_kind, support_case_id, account_id, agent_profile_id
          FROM governed_policy_subjects WHERE governed_policy_proposal_id = prior.governed_policy_proposal_id
         EXCEPT
         SELECT subject_kind, support_case_id, account_id, agent_profile_id
          FROM governed_policy_subjects WHERE governed_policy_proposal_id = policy.id)
      ) THEN
      RAISE EXCEPTION 'superseded publication does not match exact canary scope';
    END IF;
  END IF;
  IF NEW.action = 'canary' THEN
    IF NEW.resolution_contract_version_id <> policy.resolution_contract_version_id OR
        NEW.agent_profile_version_id <> policy.agent_profile_version_id OR
        NOT EXISTS (SELECT 1 FROM governed_policy_previews WHERE id = NEW.governed_policy_preview_id
          AND governed_policy_proposal_id = policy.id AND workspace_id = NEW.workspace_id) THEN
      RAISE EXCEPTION 'canary publication does not match proposal evidence';
    END IF;
  ELSE
    IF NEW.resolution_contract_version_id <> policy.prior_resolution_contract_version_id OR
        NEW.agent_profile_version_id <> policy.prior_agent_profile_version_id OR
        prior.governed_policy_proposal_id <> policy.id THEN
      RAISE EXCEPTION 'rollback publication does not match proposal history';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: validate_governed_policy_subject_count(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_governed_policy_subject_count(target_proposal_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE proposal_kind text; subject_total integer;
BEGIN
  SELECT scope_kind INTO proposal_kind FROM governed_policy_proposals WHERE id = target_proposal_id;
  IF proposal_kind IS NULL THEN RETURN; END IF;
  SELECT count(*) INTO subject_total FROM governed_policy_subjects
    WHERE governed_policy_proposal_id = target_proposal_id AND subject_kind = proposal_kind;
  IF subject_total NOT BETWEEN 1 AND 50 OR
      (proposal_kind = 'agent_profile' AND subject_total <> 1) OR
      EXISTS (SELECT 1 FROM governed_policy_subjects
        WHERE governed_policy_proposal_id = target_proposal_id AND subject_kind <> proposal_kind) THEN
    RAISE EXCEPTION 'governed policy subject scope must contain 1..50 matching records and one profile';
  END IF;
END;
$$;


--
-- Name: validate_resolution_contract_family_published(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_resolution_contract_family_published() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM resolution_contract_families
    WHERE id = NEW.id AND current_version_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'resolution contract family must have one published version';
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: validate_runtime_installation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_runtime_installation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE metadata_key text;
BEGIN
  IF NEW.allowed_role_keys <@ '["support_coordinator", "support_investigator", "resolution_drafter", "support_reviewer", "account_analyst", "risk_investigator", "success_strategist", "success_reviewer"]'::jsonb = false OR
     NEW.allowed_tools <@ '["conversation_read", "case_read", "account_read", "knowledge_search", "public_web_search", "draft_propose", "note_propose", "review_record", "web_extract"]'::jsonb = false OR
     NEW.allowed_data_classes <@ '["case_content","customer_identity","account_context","approved_knowledge","public_web_query","retrieved_memory"]'::jsonb = false OR
     NEW.allowed_role_keys <> COALESCE((SELECT jsonb_agg(value ORDER BY value) FROM (SELECT DISTINCT value FROM jsonb_array_elements(NEW.allowed_role_keys)) values), '[]'::jsonb) OR
     NEW.allowed_tools <> COALESCE((SELECT jsonb_agg(value ORDER BY value) FROM (SELECT DISTINCT value FROM jsonb_array_elements(NEW.allowed_tools)) values), '[]'::jsonb) OR
     NEW.allowed_data_classes <> COALESCE((SELECT jsonb_agg(value ORDER BY value) FROM (SELECT DISTINCT value FROM jsonb_array_elements(NEW.allowed_data_classes)) values), '[]'::jsonb) OR
     NEW.capabilities <> COALESCE((SELECT jsonb_agg(value ORDER BY value) FROM (SELECT DISTINCT value FROM jsonb_array_elements(NEW.capabilities)) values), '[]'::jsonb) THEN
    RAISE EXCEPTION 'runtime policy values must be bounded, sorted, and distinct';
  END IF;
  FOR metadata_key IN SELECT jsonb_object_keys(NEW.account_metadata) LOOP
    IF metadata_key ~* '(passw|secret|token|credential|cookie|authorization|private|session)' THEN
      RAISE EXCEPTION 'runtime account metadata cannot contain secret fields';
    END IF;
  END LOOP;
  IF NEW.approved AND (NEW.health_status <> 'available' OR NEW.compatibility_status = 'incompatible') THEN
    RAISE EXCEPTION 'unavailable or incompatible runtimes cannot be approved';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.approved AND NEW.approved AND
     ROW(OLD.adapter_key, OLD.protocol_version, OLD.executable_path, OLD.executable_version,
         OLD.account_metadata, OLD.capabilities, OLD.minimum_version, OLD.maximum_version,
         OLD.compatibility_status, OLD.execution_mode, OLD.transport) IS DISTINCT FROM
     ROW(NEW.adapter_key, NEW.protocol_version, NEW.executable_path, NEW.executable_version,
         NEW.account_metadata, NEW.capabilities, NEW.minimum_version, NEW.maximum_version,
         NEW.compatibility_status, NEW.execution_mode, NEW.transport) THEN
    RAISE EXCEPTION 'runtime detection changed without revoking approval';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: validate_runtime_routing_policy(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_runtime_routing_policy() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.profile_keys <> COALESCE((
    SELECT jsonb_agg(value ORDER BY value)
    FROM (SELECT DISTINCT value FROM jsonb_array_elements(NEW.profile_keys)) values
  ), '[]'::jsonb) THEN
    RAISE EXCEPTION 'runtime profile keys must be sorted and distinct';
  END IF;
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_health_assessments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_health_assessments (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    account_id bigint NOT NULL,
    previous_assessment_id bigint,
    score integer NOT NULL,
    risk_level character varying NOT NULL,
    trigger_kind character varying NOT NULL,
    material_change boolean NOT NULL,
    renewal_on date,
    calculated_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    health_scorecard_version_id bigint NOT NULL,
    CONSTRAINT account_health_assessments_risk CHECK (((risk_level)::text = ANY (ARRAY[('healthy'::character varying)::text, ('watch'::character varying)::text, ('at_risk'::character varying)::text]))),
    CONSTRAINT account_health_assessments_score CHECK (((score >= 0) AND (score <= 100))),
    CONSTRAINT account_health_assessments_trigger CHECK (((trigger_kind)::text = ANY (ARRAY[('input_change'::character varying)::text, ('schedule'::character varying)::text, ('renewal_window'::character varying)::text, ('human_request'::character varying)::text])))
);


--
-- Name: account_health_assessments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.account_health_assessments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: account_health_assessments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.account_health_assessments_id_seq OWNED BY public.account_health_assessments.id;


--
-- Name: account_health_inputs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_health_inputs (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    account_id bigint NOT NULL,
    input_key character varying NOT NULL,
    value_kind character varying NOT NULL,
    numeric_value numeric(18,4),
    date_value date,
    source_kind character varying NOT NULL,
    source_key character varying NOT NULL,
    source_locator character varying NOT NULL,
    observed_at timestamp(6) without time zone NOT NULL,
    supplied_by_membership_id bigint,
    supplied_by_user_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    source_namespace character varying NOT NULL,
    source_digest character varying NOT NULL,
    valid_from timestamp(6) without time zone,
    valid_until timestamp(6) without time zone,
    corrects_account_health_input_id bigint,
    CONSTRAINT account_health_inputs_business_source CHECK ((((source_namespace)::text ~ '^[a-z][a-z0-9_.:-]{0,99}$'::text) AND ((source_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT account_health_inputs_key CHECK (((input_key)::text = ANY (ARRAY[('renewal_on'::character varying)::text, ('contract_value'::character varying)::text, ('active_users'::character varying)::text, ('licensed_seats'::character varying)::text]))),
    CONSTRAINT account_health_inputs_source CHECK (((octet_length((source_key)::text) >= 1) AND (octet_length((source_key)::text) <= 255) AND ((octet_length((source_locator)::text) >= 1) AND (octet_length((source_locator)::text) <= 1000)))),
    CONSTRAINT account_health_inputs_source_kind CHECK (((source_kind)::text = ANY (ARRAY[('csv'::character varying)::text, ('api'::character varying)::text]))),
    CONSTRAINT account_health_inputs_supplier CHECK ((((supplied_by_membership_id IS NULL) AND (supplied_by_user_id IS NULL)) OR ((supplied_by_membership_id IS NOT NULL) AND (supplied_by_user_id IS NOT NULL)))),
    CONSTRAINT account_health_inputs_typed_value CHECK ((((value_kind)::text = ANY (ARRAY[('date'::character varying)::text, ('number'::character varying)::text])) AND ((((value_kind)::text = 'date'::text) AND (date_value IS NOT NULL) AND (numeric_value IS NULL)) OR (((value_kind)::text = 'number'::text) AND (numeric_value IS NOT NULL) AND (date_value IS NULL))))),
    CONSTRAINT account_health_inputs_validity CHECK (((valid_until IS NULL) OR (valid_from IS NULL) OR (valid_until >= valid_from)))
);


--
-- Name: account_health_inputs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.account_health_inputs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: account_health_inputs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.account_health_inputs_id_seq OWNED BY public.account_health_inputs.id;


--
-- Name: account_health_signals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_health_signals (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    account_health_assessment_id bigint NOT NULL,
    signal_key character varying NOT NULL,
    value_kind character varying NOT NULL,
    numeric_value numeric(18,4),
    date_value date,
    weight integer NOT NULL,
    risk_points integer NOT NULL,
    source_kind character varying NOT NULL,
    source_locator character varying NOT NULL,
    range_starts_at timestamp(6) without time zone,
    range_ends_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    evidence_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
    evidence_omitted_count integer DEFAULT 0 NOT NULL,
    CONSTRAINT account_health_signals_evidence CHECK (((jsonb_typeof(evidence_refs) = 'array'::text) AND (jsonb_array_length(evidence_refs) <= 100) AND (evidence_omitted_count >= 0))),
    CONSTRAINT account_health_signals_source CHECK (((octet_length((source_locator)::text) >= 1) AND (octet_length((source_locator)::text) <= 1000))),
    CONSTRAINT account_health_signals_source_kind CHECK (((source_kind)::text = ANY (ARRAY[('account_input'::character varying)::text, ('support_cases'::character varying)::text, ('sla'::character varying)::text, ('conversation'::character varying)::text, ('case_notes'::character varying)::text, ('case_tags'::character varying)::text, ('case_status'::character varying)::text, ('resolution_contract'::character varying)::text]))),
    CONSTRAINT account_health_signals_typed_value CHECK ((((value_kind)::text = ANY (ARRAY[('date'::character varying)::text, ('number'::character varying)::text])) AND ((((value_kind)::text = 'date'::text) AND (date_value IS NOT NULL) AND (numeric_value IS NULL)) OR (((value_kind)::text = 'number'::text) AND (numeric_value IS NOT NULL) AND (date_value IS NULL))))),
    CONSTRAINT account_health_signals_weight CHECK (((weight >= 0) AND (weight <= 100) AND ((risk_points >= 0) AND (risk_points <= weight))))
);


--
-- Name: account_health_signals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.account_health_signals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: account_health_signals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.account_health_signals_id_seq OWNED BY public.account_health_signals.id;


--
-- Name: account_merges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_merges (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    source_id bigint NOT NULL,
    target_id bigint NOT NULL,
    merged_by_id bigint NOT NULL,
    merged_at timestamp(6) without time zone NOT NULL,
    unmerged_by_id bigint,
    unmerged_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT account_merges_different_records CHECK ((source_id <> target_id)),
    CONSTRAINT account_merges_unmerge_state CHECK ((((unmerged_by_id IS NULL) AND (unmerged_at IS NULL)) OR ((unmerged_by_id IS NOT NULL) AND (unmerged_at IS NOT NULL))))
);


--
-- Name: account_merges_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.account_merges_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: account_merges_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.account_merges_id_seq OWNED BY public.account_merges.id;


--
-- Name: account_risk_investigations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_risk_investigations (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    account_id bigint NOT NULL,
    account_health_assessment_id bigint NOT NULL,
    crew_task_id bigint,
    status character varying DEFAULT 'detected'::character varying NOT NULL,
    trigger_kind character varying NOT NULL,
    opened_at timestamp(6) without time zone NOT NULL,
    resolved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT account_risk_investigations_state CHECK (((((status)::text = 'detected'::text) AND (crew_task_id IS NULL) AND (resolved_at IS NULL)) OR (((status)::text = 'investigating'::text) AND (crew_task_id IS NOT NULL) AND (resolved_at IS NULL)) OR (((status)::text = 'resolved'::text) AND (crew_task_id IS NOT NULL) AND (resolved_at IS NOT NULL)))),
    CONSTRAINT account_risk_investigations_status CHECK (((status)::text = ANY (ARRAY[('detected'::character varying)::text, ('investigating'::character varying)::text, ('resolved'::character varying)::text]))),
    CONSTRAINT account_risk_investigations_trigger CHECK (((trigger_kind)::text = ANY (ARRAY[('material_change'::character varying)::text, ('renewal_window'::character varying)::text, ('human_request'::character varying)::text])))
);


--
-- Name: account_risk_investigations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.account_risk_investigations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: account_risk_investigations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.account_risk_investigations_id_seq OWNED BY public.account_risk_investigations.id;


--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: accounts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.accounts_id_seq OWNED BY public.accounts.id;


--
-- Name: active_storage_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_attachments (
    id bigint NOT NULL,
    name character varying NOT NULL,
    record_type character varying NOT NULL,
    record_id bigint NOT NULL,
    blob_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_attachments_id_seq OWNED BY public.active_storage_attachments.id;


--
-- Name: active_storage_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_blobs (
    id bigint NOT NULL,
    key character varying NOT NULL,
    filename character varying NOT NULL,
    content_type character varying,
    metadata text,
    service_name character varying NOT NULL,
    byte_size bigint NOT NULL,
    checksum character varying,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_blobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_blobs_id_seq OWNED BY public.active_storage_blobs.id;


--
-- Name: active_storage_variant_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_variant_records (
    id bigint NOT NULL,
    blob_id bigint NOT NULL,
    variation_digest character varying NOT NULL
);


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_variant_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_variant_records_id_seq OWNED BY public.active_storage_variant_records.id;


--
-- Name: agent_profile_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_profile_versions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    agent_profile_id bigint NOT NULL,
    version_number integer NOT NULL,
    instructions text NOT NULL,
    allowed_tools jsonb DEFAULT '[]'::jsonb NOT NULL,
    runtime_profile_key character varying NOT NULL,
    fallback_profile_keys jsonb DEFAULT '[]'::jsonb NOT NULL,
    timeout_seconds integer NOT NULL,
    max_steps integer NOT NULL,
    max_tool_calls integer NOT NULL,
    review_policy character varying NOT NULL,
    created_by_membership_id bigint,
    created_by_user_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    memory_required boolean DEFAULT false NOT NULL,
    isolation_policy character varying DEFAULT 'strong_isolation_required'::character varying NOT NULL,
    CONSTRAINT agent_profile_versions_actor CHECK ((((created_by_membership_id IS NULL) AND (created_by_user_id IS NULL)) OR ((created_by_membership_id IS NOT NULL) AND (created_by_user_id IS NOT NULL)))),
    CONSTRAINT agent_profile_versions_budget CHECK (((timeout_seconds >= 30) AND (timeout_seconds <= 900) AND ((max_steps >= 1) AND (max_steps <= 20)) AND ((max_tool_calls >= 0) AND (max_tool_calls <= 50)))),
    CONSTRAINT agent_profile_versions_instructions CHECK (((octet_length(instructions) >= 1) AND (octet_length(instructions) <= 8000))),
    CONSTRAINT agent_profile_versions_isolation_policy CHECK (((isolation_policy)::text = ANY (ARRAY[('strong_isolation_required'::character varying)::text, ('host_trusted_allowed'::character varying)::text]))),
    CONSTRAINT agent_profile_versions_number CHECK ((version_number > 0)),
    CONSTRAINT agent_profile_versions_review CHECK (((review_policy)::text = ANY (ARRAY[('required'::character varying)::text, ('on_policy_flag'::character varying)::text]))),
    CONSTRAINT agent_profile_versions_runtime CHECK ((((runtime_profile_key)::text = ANY (ARRAY[('workspace_default'::character varying)::text, ('thorough'::character varying)::text, ('fast'::character varying)::text])) AND (jsonb_typeof(fallback_profile_keys) = 'array'::text) AND (jsonb_array_length(fallback_profile_keys) <= 2) AND (fallback_profile_keys <@ '["workspace_default", "thorough", "fast"]'::jsonb))),
    CONSTRAINT agent_profile_versions_tools CHECK (((jsonb_typeof(allowed_tools) = 'array'::text) AND (jsonb_array_length(allowed_tools) <= 8) AND (allowed_tools <@ '["conversation_read", "case_read", "account_read", "knowledge_search", "public_web_search", "draft_propose", "note_propose", "review_record", "web_extract"]'::jsonb)))
);


--
-- Name: agent_profile_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_profile_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_profile_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_profile_versions_id_seq OWNED BY public.agent_profile_versions.id;


--
-- Name: agent_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_profiles (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    crew_template_id bigint NOT NULL,
    role_key character varying NOT NULL,
    name character varying NOT NULL,
    current_version_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT agent_profiles_name CHECK ((((name)::text <> ''::text) AND (length((name)::text) <= 100))),
    CONSTRAINT agent_profiles_role CHECK (((role_key)::text = ANY (ARRAY[('support_coordinator'::character varying)::text, ('support_investigator'::character varying)::text, ('resolution_drafter'::character varying)::text, ('support_reviewer'::character varying)::text, ('account_analyst'::character varying)::text, ('risk_investigator'::character varying)::text, ('success_strategist'::character varying)::text, ('success_reviewer'::character varying)::text])))
);


--
-- Name: agent_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_profiles_id_seq OWNED BY public.agent_profiles.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id bigint NOT NULL,
    workspace_id bigint,
    actor_id bigint,
    actor_kind character varying NOT NULL,
    source character varying NOT NULL,
    action character varying NOT NULL,
    subject_type character varying,
    subject_id bigint,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id character varying,
    ip_address inet,
    occurred_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    expired_at timestamp(6) without time zone,
    CONSTRAINT audit_events_action_format CHECK (((action)::text ~ '^[a-z0-9]+([._][a-z0-9]+)*$'::text)),
    CONSTRAINT audit_events_actor_kind CHECK (((actor_kind)::text = ANY (ARRAY[('user'::character varying)::text, ('break_glass'::character varying)::text, ('system'::character varying)::text, ('anonymous'::character varying)::text]))),
    CONSTRAINT audit_events_actor_presence CHECK ((((actor_kind)::text = ANY (ARRAY[('user'::character varying)::text, ('break_glass'::character varying)::text])) = (actor_id IS NOT NULL))),
    CONSTRAINT audit_events_source CHECK (((source)::text = ANY (ARRAY[('web'::character varying)::text, ('job'::character varying)::text, ('task'::character varying)::text, ('runner'::character varying)::text, ('integration'::character varying)::text, ('system'::character varying)::text])))
);


--
-- Name: audit_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_events_id_seq OWNED BY public.audit_events.id;


--
-- Name: case_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_notes (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    support_case_id bigint NOT NULL,
    author_id bigint NOT NULL,
    body text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: case_notes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.case_notes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: case_notes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.case_notes_id_seq OWNED BY public.case_notes.id;


--
-- Name: case_slas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_slas (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    support_case_id bigint NOT NULL,
    sla_policy_id bigint NOT NULL,
    started_at timestamp(6) without time zone NOT NULL,
    first_response_warning_at timestamp(6) without time zone NOT NULL,
    first_response_due_at timestamp(6) without time zone NOT NULL,
    resolution_warning_at timestamp(6) without time zone NOT NULL,
    resolution_due_at timestamp(6) without time zone NOT NULL,
    first_response_status character varying DEFAULT 'pending'::character varying NOT NULL,
    resolution_status character varying DEFAULT 'pending'::character varying NOT NULL,
    first_responded_at timestamp(6) without time zone,
    resolved_at timestamp(6) without time zone,
    paused_at timestamp(6) without time zone,
    paused_business_seconds integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT case_slas_first_response_completion CHECK (((((first_response_status)::text <> 'met'::text) OR (first_responded_at IS NOT NULL)) AND ((first_responded_at IS NULL) OR ((first_response_status)::text <> 'pending'::text)))),
    CONSTRAINT case_slas_first_response_status CHECK (((first_response_status)::text = ANY (ARRAY[('pending'::character varying)::text, ('met'::character varying)::text, ('breached'::character varying)::text]))),
    CONSTRAINT case_slas_paused_seconds CHECK ((paused_business_seconds >= 0)),
    CONSTRAINT case_slas_resolution_completion CHECK (((((resolution_status)::text <> 'met'::text) OR (resolved_at IS NOT NULL)) AND ((resolved_at IS NULL) OR ((resolution_status)::text <> 'pending'::text)))),
    CONSTRAINT case_slas_resolution_status CHECK (((resolution_status)::text = ANY (ARRAY[('pending'::character varying)::text, ('met'::character varying)::text, ('breached'::character varying)::text]))),
    CONSTRAINT case_slas_warning_before_due CHECK (((first_response_warning_at < first_response_due_at) AND (resolution_warning_at < resolution_due_at)))
);


--
-- Name: case_slas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.case_slas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: case_slas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.case_slas_id_seq OWNED BY public.case_slas.id;


--
-- Name: contact_merges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contact_merges (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    source_id bigint NOT NULL,
    target_id bigint NOT NULL,
    merged_by_id bigint NOT NULL,
    merged_at timestamp(6) without time zone NOT NULL,
    unmerged_by_id bigint,
    unmerged_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contact_merges_different_records CHECK ((source_id <> target_id)),
    CONSTRAINT contact_merges_unmerge_state CHECK ((((unmerged_by_id IS NULL) AND (unmerged_at IS NULL)) OR ((unmerged_by_id IS NOT NULL) AND (unmerged_at IS NOT NULL))))
);


--
-- Name: contact_merges_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contact_merges_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contact_merges_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contact_merges_id_seq OWNED BY public.contact_merges.id;


--
-- Name: contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contacts (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    account_id bigint,
    name character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: contacts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contacts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contacts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contacts_id_seq OWNED BY public.contacts.id;


--
-- Name: conversation_message_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_message_attachments (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    conversation_message_id bigint NOT NULL,
    stored_attachment_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: conversation_message_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversation_message_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversation_message_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversation_message_attachments_id_seq OWNED BY public.conversation_message_attachments.id;


--
-- Name: conversation_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_messages (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    direction character varying NOT NULL,
    author_kind character varying NOT NULL,
    author_contact_id bigint,
    author_user_id bigint,
    external_author_name character varying,
    in_reply_to_id bigint,
    body text NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT conversation_messages_author CHECK (((((author_kind)::text = 'contact'::text) AND (author_contact_id IS NOT NULL) AND (author_user_id IS NULL) AND (external_author_name IS NULL)) OR (((author_kind)::text = 'user'::text) AND (author_contact_id IS NULL) AND (author_user_id IS NOT NULL) AND (external_author_name IS NULL)) OR (((author_kind)::text = 'external'::text) AND (author_contact_id IS NULL) AND (author_user_id IS NULL) AND (external_author_name IS NOT NULL)))),
    CONSTRAINT conversation_messages_direction CHECK (((direction)::text = ANY (ARRAY[('inbound'::character varying)::text, ('outbound'::character varying)::text])))
);


--
-- Name: conversation_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversation_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversation_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversation_messages_id_seq OWNED BY public.conversation_messages.id;


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    contact_id bigint NOT NULL,
    subject character varying,
    started_at timestamp(6) without time zone NOT NULL,
    last_message_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: conversations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversations_id_seq OWNED BY public.conversations.id;


--
-- Name: crew_artifacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.crew_artifacts (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    crew_task_id bigint NOT NULL,
    execution_run_id bigint NOT NULL,
    supersedes_artifact_id bigint,
    target_artifact_id bigint,
    artifact_key uuid DEFAULT gen_random_uuid() NOT NULL,
    version_number integer NOT NULL,
    artifact_kind character varying NOT NULL,
    body text NOT NULL,
    uncertainty text NOT NULL,
    review_outcome character varying,
    citations jsonb DEFAULT '[]'::jsonb NOT NULL,
    conflicts jsonb DEFAULT '[]'::jsonb NOT NULL,
    change_requests jsonb DEFAULT '[]'::jsonb NOT NULL,
    payload_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    schema_version integer DEFAULT 1 NOT NULL,
    resolution_contract_version_id bigint,
    required_facts jsonb DEFAULT '[]'::jsonb NOT NULL,
    material_claims jsonb DEFAULT '[]'::jsonb NOT NULL,
    proposed_actions jsonb DEFAULT '[]'::jsonb NOT NULL,
    policy_checks jsonb DEFAULT '[]'::jsonb NOT NULL,
    contract_result_state character varying,
    contract_blockers jsonb DEFAULT '[]'::jsonb NOT NULL,
    contract_evaluated_at timestamp(6) without time zone,
    governed_policy_publication_id bigint,
    CONSTRAINT crew_artifacts_collections CHECK (((jsonb_typeof(citations) = 'array'::text) AND (jsonb_array_length(citations) <= 20) AND (jsonb_typeof(conflicts) = 'array'::text) AND (jsonb_array_length(conflicts) <= 20) AND (jsonb_typeof(change_requests) = 'array'::text) AND (jsonb_array_length(change_requests) <= 20))),
    CONSTRAINT crew_artifacts_content CHECK (((octet_length(body) >= 1) AND (octet_length(body) <= 51200) AND ((octet_length(uncertainty) >= 1) AND (octet_length(uncertainty) <= 4000)))),
    CONSTRAINT crew_artifacts_contract_result CHECK (((contract_result_state IS NULL) OR ((contract_result_state)::text = ANY (ARRAY[('complete'::character varying)::text, ('blocked'::character varying)::text, ('needs_human'::character varying)::text])))),
    CONSTRAINT crew_artifacts_digest CHECK (((payload_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT crew_artifacts_governed_policy_shape CHECK (((governed_policy_publication_id IS NULL) OR (resolution_contract_version_id IS NOT NULL))),
    CONSTRAINT crew_artifacts_kind CHECK (((artifact_kind)::text = ANY (ARRAY[('investigation'::character varying)::text, ('draft'::character varying)::text, ('quality_review'::character varying)::text, ('account_analysis'::character varying)::text, ('risk_investigation'::character varying)::text, ('intervention_plan'::character varying)::text, ('success_review'::character varying)::text]))),
    CONSTRAINT crew_artifacts_resolution_collections CHECK (((jsonb_typeof(required_facts) = 'array'::text) AND (jsonb_array_length(required_facts) <= 20) AND (jsonb_typeof(material_claims) = 'array'::text) AND (jsonb_array_length(material_claims) <= 20) AND (jsonb_typeof(proposed_actions) = 'array'::text) AND (jsonb_array_length(proposed_actions) <= 20) AND (jsonb_typeof(policy_checks) = 'array'::text) AND (jsonb_array_length(policy_checks) <= 4) AND (jsonb_typeof(contract_blockers) = 'array'::text) AND (jsonb_array_length(contract_blockers) <= 100))),
    CONSTRAINT crew_artifacts_resolution_grounding CHECK (public.resolution_grounding_valid(required_facts, material_claims)),
    CONSTRAINT crew_artifacts_resolution_shape CHECK ((((schema_version = 1) AND (resolution_contract_version_id IS NULL) AND (contract_result_state IS NULL) AND (contract_evaluated_at IS NULL) AND (jsonb_array_length(required_facts) = 0) AND (jsonb_array_length(material_claims) = 0) AND (jsonb_array_length(proposed_actions) = 0) AND (jsonb_array_length(policy_checks) = 0) AND (jsonb_array_length(contract_blockers) = 0)) OR ((schema_version = 2) AND (resolution_contract_version_id IS NOT NULL) AND (contract_result_state IS NOT NULL) AND (contract_evaluated_at IS NOT NULL) AND ((jsonb_array_length(required_facts) >= 1) AND (jsonb_array_length(required_facts) <= 20)) AND ((jsonb_array_length(material_claims) >= 1) AND (jsonb_array_length(material_claims) <= 20))))),
    CONSTRAINT crew_artifacts_review_outcome CHECK (((review_outcome IS NULL) OR ((review_outcome)::text = ANY (ARRAY[('approved'::character varying)::text, ('changes_requested'::character varying)::text])))),
    CONSTRAINT crew_artifacts_review_shape CHECK (((((artifact_kind)::text = ANY (ARRAY[('quality_review'::character varying)::text, ('success_review'::character varying)::text])) AND (target_artifact_id IS NOT NULL) AND (review_outcome IS NOT NULL)) OR (((artifact_kind)::text <> ALL (ARRAY[('quality_review'::character varying)::text, ('success_review'::character varying)::text])) AND (target_artifact_id IS NULL) AND (review_outcome IS NULL)))),
    CONSTRAINT crew_artifacts_schema_version CHECK ((schema_version = ANY (ARRAY[1, 2]))),
    CONSTRAINT crew_artifacts_version CHECK ((version_number > 0))
);


--
-- Name: crew_artifacts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.crew_artifacts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: crew_artifacts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.crew_artifacts_id_seq OWNED BY public.crew_artifacts.id;


--
-- Name: crew_task_dependencies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.crew_task_dependencies (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    crew_task_id bigint NOT NULL,
    depends_on_task_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT crew_task_dependencies_not_self CHECK ((crew_task_id <> depends_on_task_id))
);


--
-- Name: crew_task_dependencies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.crew_task_dependencies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: crew_task_dependencies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.crew_task_dependencies_id_seq OWNED BY public.crew_task_dependencies.id;


--
-- Name: crew_task_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.crew_task_events (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    crew_task_id bigint NOT NULL,
    sequence_number integer NOT NULL,
    event_kind character varying NOT NULL,
    source character varying NOT NULL,
    actor_membership_id bigint,
    actor_user_id bigint,
    from_status character varying,
    to_status character varying NOT NULL,
    from_agent_profile_id bigint,
    to_agent_profile_id bigint NOT NULL,
    from_agent_profile_version_id bigint,
    to_agent_profile_version_id bigint NOT NULL,
    body text,
    evidence_kind character varying,
    evidence_locator character varying,
    review_outcome character varying,
    outcome_kind character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    from_governed_policy_publication_id bigint,
    to_governed_policy_publication_id bigint,
    from_resolution_contract_version_id bigint,
    to_resolution_contract_version_id bigint,
    CONSTRAINT crew_task_events_actor CHECK ((((actor_membership_id IS NULL) AND (actor_user_id IS NULL)) OR ((actor_membership_id IS NOT NULL) AND (actor_user_id IS NOT NULL)))),
    CONSTRAINT crew_task_events_body CHECK (((body IS NULL) OR ((octet_length(body) >= 1) AND (octet_length(body) <= 20000)))),
    CONSTRAINT crew_task_events_evidence_kind CHECK (((evidence_kind IS NULL) OR ((evidence_kind)::text = ANY (ARRAY[('conversation'::character varying)::text, ('case'::character varying)::text, ('account'::character varying)::text, ('knowledge'::character varying)::text, ('public_web'::character varying)::text, ('other'::character varying)::text])))),
    CONSTRAINT crew_task_events_evidence_locator CHECK (((evidence_locator IS NULL) OR ((octet_length((evidence_locator)::text) >= 1) AND (octet_length((evidence_locator)::text) <= 2000)))),
    CONSTRAINT crew_task_events_from_governed_policy_shape CHECK (((from_governed_policy_publication_id IS NULL) OR ((from_resolution_contract_version_id IS NOT NULL) AND (from_agent_profile_version_id IS NOT NULL)))),
    CONSTRAINT crew_task_events_kind CHECK (((event_kind)::text = ANY (ARRAY[('created'::character varying)::text, ('status_changed'::character varying)::text, ('handoff'::character varying)::text, ('comment'::character varying)::text, ('evidence_added'::character varying)::text, ('review_requested'::character varying)::text, ('review_resolved'::character varying)::text, ('outcome_recorded'::character varying)::text]))),
    CONSTRAINT crew_task_events_outcome_kind CHECK (((outcome_kind IS NULL) OR ((outcome_kind)::text = ANY (ARRAY[('completed'::character varying)::text, ('failed'::character varying)::text, ('canceled'::character varying)::text])))),
    CONSTRAINT crew_task_events_review_outcome CHECK (((review_outcome IS NULL) OR ((review_outcome)::text = ANY (ARRAY[('approved'::character varying)::text, ('changes_requested'::character varying)::text])))),
    CONSTRAINT crew_task_events_sequence CHECK ((sequence_number > 0)),
    CONSTRAINT crew_task_events_source CHECK (((source)::text = ANY (ARRAY[('web'::character varying)::text, ('task'::character varying)::text, ('runner'::character varying)::text, ('system'::character varying)::text]))),
    CONSTRAINT crew_task_events_to_governed_policy_shape CHECK (((to_governed_policy_publication_id IS NULL) OR ((to_resolution_contract_version_id IS NOT NULL) AND (to_agent_profile_version_id IS NOT NULL))))
);


--
-- Name: crew_task_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.crew_task_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: crew_task_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.crew_task_events_id_seq OWNED BY public.crew_task_events.id;


--
-- Name: crew_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.crew_tasks (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    task_key uuid DEFAULT gen_random_uuid() NOT NULL,
    scope_kind character varying NOT NULL,
    support_case_id bigint,
    account_id bigint,
    crew_template_id bigint NOT NULL,
    assigned_agent_profile_id bigint NOT NULL,
    assigned_agent_profile_version_id bigint NOT NULL,
    owner_membership_id bigint NOT NULL,
    owner_user_id bigint NOT NULL,
    title character varying NOT NULL,
    input_context text NOT NULL,
    expected_output text NOT NULL,
    status character varying NOT NULL,
    current_event_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    governed_policy_publication_id bigint,
    resolution_contract_version_id bigint,
    CONSTRAINT crew_tasks_content CHECK (((octet_length((title)::text) >= 1) AND (octet_length((title)::text) <= 200) AND ((octet_length(input_context) >= 1) AND (octet_length(input_context) <= 8000)) AND ((octet_length(expected_output) >= 1) AND (octet_length(expected_output) <= 8000)))),
    CONSTRAINT crew_tasks_governed_policy_shape CHECK (((governed_policy_publication_id IS NULL) OR (resolution_contract_version_id IS NOT NULL))),
    CONSTRAINT crew_tasks_scope CHECK (((((scope_kind)::text = 'support_case'::text) AND (support_case_id IS NOT NULL) AND (account_id IS NULL)) OR (((scope_kind)::text = 'account'::text) AND (account_id IS NOT NULL) AND (support_case_id IS NULL)))),
    CONSTRAINT crew_tasks_status CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('ready'::character varying)::text, ('in_progress'::character varying)::text, ('blocked'::character varying)::text, ('review_requested'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text, ('canceled'::character varying)::text])))
);


--
-- Name: crew_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.crew_tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: crew_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.crew_tasks_id_seq OWNED BY public.crew_tasks.id;


--
-- Name: crew_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.crew_templates (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    crew_kind character varying NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT crew_templates_kind CHECK (((crew_kind)::text = ANY (ARRAY[('support'::character varying)::text, ('customer_success'::character varying)::text]))),
    CONSTRAINT crew_templates_name CHECK ((((name)::text <> ''::text) AND (length((name)::text) <= 100)))
);


--
-- Name: crew_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.crew_templates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: crew_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.crew_templates_id_seq OWNED BY public.crew_templates.id;


--
-- Name: customer_success_intervention_outcome_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_success_intervention_outcome_reviews (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    customer_success_intervention_id bigint NOT NULL,
    before_account_health_assessment_id bigint NOT NULL,
    after_account_health_assessment_id bigint NOT NULL,
    reviewed_by_membership_id bigint NOT NULL,
    before_snapshot jsonb NOT NULL,
    after_snapshot jsonb NOT NULL,
    changed_facts jsonb DEFAULT '[]'::jsonb NOT NULL,
    unchanged_facts jsonb DEFAULT '[]'::jsonb NOT NULL,
    uncertainty text NOT NULL,
    observed_association text NOT NULL,
    reviewed_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT customer_success_outcome_reviews_assessments CHECK ((before_account_health_assessment_id <> after_account_health_assessment_id)),
    CONSTRAINT customer_success_outcome_reviews_content CHECK (((octet_length(uncertainty) >= 1) AND (octet_length(uncertainty) <= 2000) AND ((octet_length(observed_association) >= 1) AND (octet_length(observed_association) <= 2000)))),
    CONSTRAINT customer_success_outcome_reviews_snapshots CHECK (((jsonb_typeof(before_snapshot) = 'object'::text) AND (jsonb_typeof(after_snapshot) = 'object'::text) AND (octet_length((before_snapshot)::text) <= 131072) AND (octet_length((after_snapshot)::text) <= 131072) AND (jsonb_typeof(changed_facts) = 'array'::text) AND (jsonb_array_length(changed_facts) <= 50) AND (jsonb_typeof(unchanged_facts) = 'array'::text) AND (jsonb_array_length(unchanged_facts) <= 50)))
);


--
-- Name: customer_success_intervention_outcome_reviews_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.customer_success_intervention_outcome_reviews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: customer_success_intervention_outcome_reviews_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.customer_success_intervention_outcome_reviews_id_seq OWNED BY public.customer_success_intervention_outcome_reviews.id;


--
-- Name: customer_success_interventions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_success_interventions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    account_id bigint NOT NULL,
    account_health_assessment_id bigint NOT NULL,
    account_risk_investigation_id bigint,
    proposing_crew_artifact_id bigint NOT NULL,
    accountable_membership_id bigint NOT NULL,
    proposed_by_membership_id bigint NOT NULL,
    status character varying DEFAULT 'proposed'::character varying NOT NULL,
    supporting_evidence jsonb DEFAULT '[]'::jsonb NOT NULL,
    expected_observable_change text NOT NULL,
    target_on date NOT NULL,
    reason text NOT NULL,
    proposed_at timestamp(6) without time zone NOT NULL,
    approved_by_membership_id bigint,
    approved_at timestamp(6) without time zone,
    completed_by_membership_id bigint,
    completed_at timestamp(6) without time zone,
    abandoned_by_membership_id bigint,
    abandoned_at timestamp(6) without time zone,
    abandonment_reason text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT customer_success_interventions_content CHECK (((octet_length(expected_observable_change) >= 1) AND (octet_length(expected_observable_change) <= 2000) AND ((octet_length(reason) >= 1) AND (octet_length(reason) <= 1000)) AND ((abandonment_reason IS NULL) OR ((octet_length(abandonment_reason) >= 1) AND (octet_length(abandonment_reason) <= 1000))))),
    CONSTRAINT customer_success_interventions_evidence CHECK (((jsonb_typeof(supporting_evidence) = 'array'::text) AND ((jsonb_array_length(supporting_evidence) >= 1) AND (jsonb_array_length(supporting_evidence) <= 20)))),
    CONSTRAINT customer_success_interventions_state CHECK (((((status)::text = 'proposed'::text) AND (approved_by_membership_id IS NULL) AND (approved_at IS NULL) AND (completed_by_membership_id IS NULL) AND (completed_at IS NULL) AND (abandoned_by_membership_id IS NULL) AND (abandoned_at IS NULL) AND (abandonment_reason IS NULL)) OR (((status)::text = 'approved'::text) AND (approved_by_membership_id IS NOT NULL) AND (approved_at IS NOT NULL) AND (completed_by_membership_id IS NULL) AND (completed_at IS NULL) AND (abandoned_by_membership_id IS NULL) AND (abandoned_at IS NULL) AND (abandonment_reason IS NULL)) OR (((status)::text = ANY (ARRAY[('completed'::character varying)::text, ('reviewed'::character varying)::text])) AND (approved_by_membership_id IS NOT NULL) AND (approved_at IS NOT NULL) AND (completed_by_membership_id IS NOT NULL) AND (completed_at IS NOT NULL) AND (abandoned_by_membership_id IS NULL) AND (abandoned_at IS NULL) AND (abandonment_reason IS NULL)) OR (((status)::text = 'abandoned'::text) AND (completed_by_membership_id IS NULL) AND (completed_at IS NULL) AND (abandoned_by_membership_id IS NOT NULL) AND (abandoned_at IS NOT NULL) AND (abandonment_reason IS NOT NULL)))),
    CONSTRAINT customer_success_interventions_status CHECK (((status)::text = ANY (ARRAY[('proposed'::character varying)::text, ('approved'::character varying)::text, ('completed'::character varying)::text, ('abandoned'::character varying)::text, ('reviewed'::character varying)::text])))
);


--
-- Name: customer_success_interventions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.customer_success_interventions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: customer_success_interventions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.customer_success_interventions_id_seq OWNED BY public.customer_success_interventions.id;


--
-- Name: email_draft_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_draft_attachments (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    email_draft_id bigint NOT NULL,
    stored_attachment_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: email_draft_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_draft_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_draft_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_draft_attachments_id_seq OWNED BY public.email_draft_attachments.id;


--
-- Name: email_drafts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_drafts (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    support_case_id bigint NOT NULL,
    email_thread_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    updated_by_id bigint NOT NULL,
    body text NOT NULL,
    status character varying DEFAULT 'ready'::character varying NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    source_crew_artifact_id bigint,
    generated_body_digest character varying,
    generated_contract_result_state character varying,
    human_edited_by_membership_id bigint,
    human_edited_by_user_id bigint,
    human_edited_at timestamp(6) without time zone,
    CONSTRAINT email_drafts_body_size CHECK ((octet_length(body) <= 1048576)),
    CONSTRAINT email_drafts_contract_result CHECK (((generated_contract_result_state IS NULL) OR ((generated_contract_result_state)::text = ANY (ARRAY[('complete'::character varying)::text, ('blocked'::character varying)::text, ('needs_human'::character varying)::text])))),
    CONSTRAINT email_drafts_generated_digest CHECK (((generated_body_digest IS NULL) OR ((generated_body_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT email_drafts_provenance_shape CHECK ((((source_crew_artifact_id IS NULL) AND (generated_body_digest IS NULL) AND (generated_contract_result_state IS NULL) AND (human_edited_by_membership_id IS NULL) AND (human_edited_by_user_id IS NULL) AND (human_edited_at IS NULL)) OR ((source_crew_artifact_id IS NOT NULL) AND (generated_body_digest IS NOT NULL) AND (((human_edited_by_membership_id IS NULL) AND (human_edited_by_user_id IS NULL) AND (human_edited_at IS NULL)) OR ((human_edited_by_membership_id IS NOT NULL) AND (human_edited_by_user_id IS NOT NULL) AND (human_edited_at IS NOT NULL)))))),
    CONSTRAINT email_drafts_status CHECK (((status)::text = ANY (ARRAY[('ready'::character varying)::text, ('sending'::character varying)::text, ('sent'::character varying)::text])))
);


--
-- Name: email_drafts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_drafts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_drafts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_drafts_id_seq OWNED BY public.email_drafts.id;


--
-- Name: email_message_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_message_links (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    shared_email_inbox_id bigint NOT NULL,
    email_thread_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    conversation_message_id bigint NOT NULL,
    message_id character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    reply_to_address character varying,
    CONSTRAINT email_message_links_reply_to_address CHECK (((reply_to_address IS NULL) OR ((length((reply_to_address)::text) <= 254) AND ((reply_to_address)::text ~ '^[^[:space:]<>@]+@[^[:space:]<>@]+$'::text))))
);


--
-- Name: email_message_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_message_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_message_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_message_links_id_seq OWNED BY public.email_message_links.id;


--
-- Name: email_threads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_threads (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    shared_email_inbox_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    thread_key character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: email_threads_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_threads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_threads_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_threads_id_seq OWNED BY public.email_threads.id;


--
-- Name: execution_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.execution_events (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    execution_run_id bigint NOT NULL,
    event_key uuid NOT NULL,
    sequence_number integer NOT NULL,
    event_type character varying NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    payload_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT execution_events_payload CHECK (((octet_length((data)::text) <= 131072) AND ((payload_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT execution_events_sequence CHECK ((sequence_number > 0)),
    CONSTRAINT execution_events_type CHECK (((event_type)::text = ANY (ARRAY[('run.admitted'::character varying)::text, ('run.started'::character varying)::text, ('tool.completed'::character varying)::text, ('output.produced'::character varying)::text, ('usage.observed'::character varying)::text, ('run.completed'::character varying)::text, ('run.failed'::character varying)::text, ('run.timed_out'::character varying)::text, ('run.canceled'::character varying)::text, ('run.policy_denied'::character varying)::text])))
);


--
-- Name: execution_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.execution_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: execution_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.execution_events_id_seq OWNED BY public.execution_events.id;


--
-- Name: execution_memory_selections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.execution_memory_selections (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    execution_run_id bigint NOT NULL,
    memory_record_id bigint NOT NULL,
    rank integer NOT NULL,
    relevance_score numeric(6,5) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT execution_memory_selections_bounds CHECK (((rank >= 1) AND (rank <= 8) AND ((relevance_score >= 0.00000) AND (relevance_score <= 1.00000))))
);


--
-- Name: execution_memory_selections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.execution_memory_selections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: execution_memory_selections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.execution_memory_selections_id_seq OWNED BY public.execution_memory_selections.id;


--
-- Name: execution_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.execution_runs (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    crew_task_id bigint NOT NULL,
    agent_profile_id bigint NOT NULL,
    agent_profile_version_id bigint NOT NULL,
    run_key uuid DEFAULT gen_random_uuid() NOT NULL,
    request_key character varying NOT NULL,
    attempt_number integer NOT NULL,
    runtime_profile_key character varying NOT NULL,
    status character varying DEFAULT 'admitting'::character varying NOT NULL,
    current_sequence integer DEFAULT 0 NOT NULL,
    current_event_id bigint,
    admission_attempt_count integer DEFAULT 0 NOT NULL,
    admission_attempted_at timestamp(6) without time zone,
    last_admission_error character varying,
    input_units bigint DEFAULT 0 NOT NULL,
    output_units bigint DEFAULT 0 NOT NULL,
    output text,
    failure_code character varying,
    retryable boolean,
    admitted_at timestamp(6) without time zone,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    input_context text NOT NULL,
    input_artifact_id bigint,
    runtime_installation_id bigint,
    selected_runtime_detection_key character varying DEFAULT '0000000000000000000000000000000000000000000000000000000000000000'::character varying NOT NULL,
    selected_runtime_configuration_fingerprint character varying DEFAULT '0000000000000000000000000000000000000000000000000000000000000000'::character varying NOT NULL,
    selected_effective_model character varying DEFAULT 'legacy_unknown'::character varying NOT NULL,
    selected_execution_mode character varying DEFAULT 'legacy_unknown'::character varying NOT NULL,
    selected_isolation_policy character varying DEFAULT 'legacy_unknown'::character varying NOT NULL,
    selected_adapter_key character varying DEFAULT 'scripted'::character varying NOT NULL,
    selected_runtime_profile_key character varying DEFAULT 'workspace_default'::character varying NOT NULL,
    runtime_selection_reason character varying DEFAULT 'primary'::character varying NOT NULL,
    runtime_selection_detail character varying DEFAULT 'Primary profile selected.'::character varying NOT NULL,
    disclosed_data_classes jsonb DEFAULT '[]'::jsonb NOT NULL,
    max_input_units bigint DEFAULT 100000 NOT NULL,
    max_output_units bigint DEFAULT 25000 NOT NULL,
    memory_context_status character varying DEFAULT 'not_applicable'::character varying NOT NULL,
    memory_context_detail character varying,
    usage_rate_version_id bigint,
    governed_policy_publication_id bigint,
    resolution_contract_version_id bigint,
    requested_by_membership_id bigint,
    selected_personal_account_key uuid,
    CONSTRAINT execution_runs_admission_error CHECK (((last_admission_error IS NULL) OR ((octet_length((last_admission_error)::text) >= 1) AND (octet_length((last_admission_error)::text) <= 100)))),
    CONSTRAINT execution_runs_bounds CHECK (((octet_length((request_key)::text) >= 1) AND (octet_length((request_key)::text) <= 128) AND (attempt_number > 0) AND (current_sequence >= 0) AND (admission_attempt_count >= 0) AND (input_units >= 0) AND (output_units >= 0))),
    CONSTRAINT execution_runs_disclosure_budgets CHECK (((jsonb_typeof(disclosed_data_classes) = 'array'::text) AND (jsonb_array_length(disclosed_data_classes) <= 8) AND (disclosed_data_classes <@ '["case_content", "customer_identity", "account_context", "approved_knowledge", "public_web_query", "retrieved_memory"]'::jsonb) AND ((max_input_units >= 1) AND (max_input_units <= 10000000)) AND ((max_output_units >= 1) AND (max_output_units <= 10000000)))),
    CONSTRAINT execution_runs_execution_boundary CHECK ((((selected_execution_mode)::text = ANY (ARRAY[('bounded'::character varying)::text, ('host_trusted'::character varying)::text, ('strong_isolated'::character varying)::text, ('legacy_unknown'::character varying)::text])) AND ((selected_isolation_policy)::text = ANY (ARRAY[('strong_isolation_required'::character varying)::text, ('host_trusted_allowed'::character varying)::text, ('legacy_unknown'::character varying)::text])) AND ((((selected_execution_mode)::text = 'legacy_unknown'::text) AND ((selected_isolation_policy)::text = 'legacy_unknown'::text)) OR (((selected_execution_mode)::text = ANY (ARRAY[('bounded'::character varying)::text, ('strong_isolated'::character varying)::text])) AND ((selected_isolation_policy)::text = ANY (ARRAY[('strong_isolation_required'::character varying)::text, ('host_trusted_allowed'::character varying)::text]))) OR (((selected_execution_mode)::text = 'host_trusted'::text) AND ((selected_isolation_policy)::text = 'host_trusted_allowed'::text))))),
    CONSTRAINT execution_runs_failure_code CHECK (((failure_code IS NULL) OR ((octet_length((failure_code)::text) >= 1) AND (octet_length((failure_code)::text) <= 100)))),
    CONSTRAINT execution_runs_governed_policy_shape CHECK (((governed_policy_publication_id IS NULL) OR (resolution_contract_version_id IS NOT NULL))),
    CONSTRAINT execution_runs_input_context CHECK (((octet_length(input_context) >= 1) AND (octet_length(input_context) <= 131072))),
    CONSTRAINT execution_runs_memory_context CHECK ((((memory_context_status)::text = ANY (ARRAY[('not_applicable'::character varying)::text, ('available'::character varying)::text, ('degraded'::character varying)::text])) AND ((((memory_context_status)::text = 'degraded'::text) AND (memory_context_detail IS NOT NULL)) OR (((memory_context_status)::text <> 'degraded'::text) AND (memory_context_detail IS NULL))))),
    CONSTRAINT execution_runs_memory_context_detail CHECK (((memory_context_detail IS NULL) OR ((octet_length((memory_context_detail)::text) >= 1) AND (octet_length((memory_context_detail)::text) <= 100)))),
    CONSTRAINT execution_runs_output CHECK (((output IS NULL) OR (octet_length(output) <= 102400))),
    CONSTRAINT execution_runs_personal_requester CHECK (((selected_personal_account_key IS NULL) OR (requested_by_membership_id IS NOT NULL))),
    CONSTRAINT execution_runs_runtime_configuration_snapshot CHECK ((((selected_runtime_configuration_fingerprint)::text ~ '^[0-9a-f]{64}$'::text) AND ((octet_length((selected_effective_model)::text) >= 1) AND (octet_length((selected_effective_model)::text) <= 200)) AND ((selected_effective_model)::text !~ '[\r\n]'::text))),
    CONSTRAINT execution_runs_runtime_selection CHECK ((((selected_runtime_detection_key)::text ~ '^[0-9a-f]{64}$'::text) AND ((selected_adapter_key)::text ~ '^[a-z][a-z0-9_]{0,63}$'::text) AND ((selected_runtime_profile_key)::text = ANY (ARRAY[('workspace_default'::character varying)::text, ('thorough'::character varying)::text, ('fast'::character varying)::text])) AND ((runtime_selection_reason)::text = ANY (ARRAY[('primary'::character varying)::text, ('fallback'::character varying)::text])))),
    CONSTRAINT execution_runs_runtime_selection_detail CHECK (((octet_length((runtime_selection_detail)::text) >= 1) AND (octet_length((runtime_selection_detail)::text) <= 500))),
    CONSTRAINT execution_runs_status CHECK (((status)::text = ANY (ARRAY[('admitting'::character varying)::text, ('admitted'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text, ('timed_out'::character varying)::text, ('canceled'::character varying)::text, ('policy_denied'::character varying)::text])))
);


--
-- Name: execution_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.execution_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: execution_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.execution_runs_id_seq OWNED BY public.execution_runs.id;


--
-- Name: governed_policy_previews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.governed_policy_previews (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    governed_policy_proposal_id bigint NOT NULL,
    evidence_digest character varying NOT NULL,
    results_digest character varying NOT NULL,
    source_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    results jsonb DEFAULT '[]'::jsonb NOT NULL,
    subject_count integer NOT NULL,
    created_by_membership_id bigint NOT NULL,
    created_by_user_id bigint NOT NULL,
    previewed_at timestamp(6) without time zone NOT NULL,
    expired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT policy_previews_bounded CHECK ((((evidence_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((results_digest)::text ~ '^[0-9a-f]{64}$'::text) AND (jsonb_typeof(source_snapshot) = 'object'::text) AND (jsonb_typeof(results) = 'array'::text) AND ((subject_count >= 1) AND (subject_count <= 50)) AND (jsonb_array_length(results) = subject_count) AND (octet_length((source_snapshot)::text) <= 524288) AND (octet_length((results)::text) <= 524288)))
);


--
-- Name: governed_policy_previews_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.governed_policy_previews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: governed_policy_previews_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.governed_policy_previews_id_seq OWNED BY public.governed_policy_previews.id;


--
-- Name: governed_policy_proposals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.governed_policy_proposals (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    resolution_contract_family_id bigint NOT NULL,
    agent_profile_id bigint NOT NULL,
    prior_resolution_contract_version_id bigint NOT NULL,
    resolution_contract_version_id bigint NOT NULL,
    prior_agent_profile_version_id bigint NOT NULL,
    agent_profile_version_id bigint NOT NULL,
    scope_kind character varying NOT NULL,
    reason character varying NOT NULL,
    created_by_membership_id bigint NOT NULL,
    created_by_user_id bigint NOT NULL,
    expired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT policy_proposals_reason CHECK (((octet_length(btrim((reason)::text)) >= 1) AND (octet_length(btrim((reason)::text)) <= 500))),
    CONSTRAINT policy_proposals_scope CHECK (((scope_kind)::text = ANY (ARRAY[('support_case'::character varying)::text, ('account'::character varying)::text, ('agent_profile'::character varying)::text])))
);


--
-- Name: governed_policy_proposals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.governed_policy_proposals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: governed_policy_proposals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.governed_policy_proposals_id_seq OWNED BY public.governed_policy_proposals.id;


--
-- Name: governed_policy_publications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.governed_policy_publications (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    governed_policy_proposal_id bigint NOT NULL,
    governed_policy_preview_id bigint,
    supersedes_publication_id bigint,
    action character varying NOT NULL,
    resolution_contract_version_id bigint NOT NULL,
    agent_profile_version_id bigint NOT NULL,
    reason character varying NOT NULL,
    created_by_membership_id bigint NOT NULL,
    created_by_user_id bigint NOT NULL,
    published_at timestamp(6) without time zone NOT NULL,
    expired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT policy_publications_shape CHECK ((((action)::text = ANY (ARRAY[('canary'::character varying)::text, ('rollback'::character varying)::text])) AND ((octet_length(btrim((reason)::text)) >= 1) AND (octet_length(btrim((reason)::text)) <= 500)) AND ((((action)::text = 'canary'::text) AND (governed_policy_preview_id IS NOT NULL)) OR (((action)::text = 'rollback'::text) AND (governed_policy_preview_id IS NULL) AND (supersedes_publication_id IS NOT NULL)))))
);


--
-- Name: governed_policy_publications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.governed_policy_publications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: governed_policy_publications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.governed_policy_publications_id_seq OWNED BY public.governed_policy_publications.id;


--
-- Name: governed_policy_subjects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.governed_policy_subjects (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    governed_policy_proposal_id bigint NOT NULL,
    subject_kind character varying NOT NULL,
    support_case_id bigint,
    account_id bigint,
    agent_profile_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT policy_subjects_shape CHECK (((((subject_kind)::text = 'support_case'::text) AND (support_case_id IS NOT NULL) AND (account_id IS NULL) AND (agent_profile_id IS NULL)) OR (((subject_kind)::text = 'account'::text) AND (support_case_id IS NULL) AND (account_id IS NOT NULL) AND (agent_profile_id IS NULL)) OR (((subject_kind)::text = 'agent_profile'::text) AND (support_case_id IS NULL) AND (account_id IS NULL) AND (agent_profile_id IS NOT NULL))))
);


--
-- Name: governed_policy_subjects_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.governed_policy_subjects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: governed_policy_subjects_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.governed_policy_subjects_id_seq OWNED BY public.governed_policy_subjects.id;


--
-- Name: health_scorecard_backtests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_scorecard_backtests (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    health_scorecard_version_id bigint NOT NULL,
    membership_id bigint NOT NULL,
    user_id bigint NOT NULL,
    source_digest character varying NOT NULL,
    results jsonb DEFAULT '{}'::jsonb NOT NULL,
    sample_count integer NOT NULL,
    generated_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT health_scorecard_backtests_digest CHECK (((source_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT health_scorecard_backtests_sample_count CHECK (((sample_count >= 0) AND (sample_count <= 500)))
);


--
-- Name: health_scorecard_backtests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.health_scorecard_backtests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: health_scorecard_backtests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.health_scorecard_backtests_id_seq OWNED BY public.health_scorecard_backtests.id;


--
-- Name: health_scorecard_design_turns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_scorecard_design_turns (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    health_scorecard_id bigint NOT NULL,
    health_scorecard_version_id bigint NOT NULL,
    membership_id bigint NOT NULL,
    user_id bigint NOT NULL,
    prompt text NOT NULL,
    response text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT health_scorecard_design_turns_content CHECK (((octet_length(prompt) >= 1) AND (octet_length(prompt) <= 4000) AND ((octet_length(response) >= 1) AND (octet_length(response) <= 8000))))
);


--
-- Name: health_scorecard_design_turns_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.health_scorecard_design_turns_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: health_scorecard_design_turns_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.health_scorecard_design_turns_id_seq OWNED BY public.health_scorecard_design_turns.id;


--
-- Name: health_scorecard_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_scorecard_versions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    health_scorecard_id bigint NOT NULL,
    version_number integer NOT NULL,
    design_prompt text NOT NULL,
    explanation text NOT NULL,
    definition jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by_membership_id bigint,
    created_by_user_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT health_scorecard_versions_actor CHECK ((((created_by_membership_id IS NULL) AND (created_by_user_id IS NULL)) OR ((created_by_membership_id IS NOT NULL) AND (created_by_user_id IS NOT NULL)))),
    CONSTRAINT health_scorecard_versions_content CHECK (((octet_length(design_prompt) >= 1) AND (octet_length(design_prompt) <= 4000) AND ((octet_length(explanation) >= 1) AND (octet_length(explanation) <= 8000)))),
    CONSTRAINT health_scorecard_versions_number CHECK ((version_number > 0))
);


--
-- Name: health_scorecard_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.health_scorecard_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: health_scorecard_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.health_scorecard_versions_id_seq OWNED BY public.health_scorecard_versions.id;


--
-- Name: health_scorecards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_scorecards (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    name character varying NOT NULL,
    current_version_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: health_scorecards_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.health_scorecards_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: health_scorecards_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.health_scorecards_id_seq OWNED BY public.health_scorecards.id;


--
-- Name: identity_match_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_match_candidates (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    source_identity_id bigint NOT NULL,
    account_id bigint,
    contact_id bigint,
    key_kind character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT identity_match_candidates_key_kind CHECK (((key_kind)::text = ANY (ARRAY[('email'::character varying)::text, ('domain'::character varying)::text]))),
    CONSTRAINT identity_match_candidates_one_record CHECK (((((account_id IS NOT NULL))::integer + ((contact_id IS NOT NULL))::integer) = 1))
);


--
-- Name: identity_match_candidates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.identity_match_candidates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: identity_match_candidates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.identity_match_candidates_id_seq OWNED BY public.identity_match_candidates.id;


--
-- Name: inbound_email_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inbound_email_deliveries (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    shared_email_inbox_id bigint NOT NULL,
    source_message_id character varying NOT NULL,
    content_sha256 character varying NOT NULL,
    raw_email bytea NOT NULL,
    status character varying DEFAULT 'received'::character varying NOT NULL,
    failure_code character varying,
    conversation_id bigint,
    conversation_message_id bigint,
    received_at timestamp(6) without time zone NOT NULL,
    processed_at timestamp(6) without time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_attempted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT inbound_email_deliveries_attempts CHECK ((((attempt_count = 0) AND (last_attempted_at IS NULL)) OR ((attempt_count > 0) AND (last_attempted_at IS NOT NULL)))),
    CONSTRAINT inbound_email_deliveries_digest CHECK (((content_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT inbound_email_deliveries_failure_code CHECK (((failure_code IS NULL) OR ((failure_code)::text = ANY (ARRAY[('parse_error'::character varying)::text, ('missing_sender'::character varying)::text, ('missing_message_id'::character varying)::text, ('message_id_conflict'::character varying)::text, ('empty_body'::character varying)::text, ('body_too_large'::character varying)::text, ('identity_ambiguous'::character varying)::text, ('identity_error'::character varying)::text, ('persistence_error'::character varying)::text])))),
    CONSTRAINT inbound_email_deliveries_size CHECK ((octet_length(raw_email) <= 10485760)),
    CONSTRAINT inbound_email_deliveries_state CHECK (((((status)::text = 'received'::text) AND (failure_code IS NULL) AND (conversation_id IS NULL) AND (conversation_message_id IS NULL) AND (processed_at IS NULL)) OR (((status)::text = 'processed'::text) AND (failure_code IS NULL) AND (conversation_id IS NOT NULL) AND (conversation_message_id IS NOT NULL) AND (processed_at IS NOT NULL)) OR (((status)::text = 'failed'::text) AND (failure_code IS NOT NULL) AND (conversation_id IS NULL) AND (conversation_message_id IS NULL) AND (processed_at IS NOT NULL)))),
    CONSTRAINT inbound_email_deliveries_status CHECK (((status)::text = ANY (ARRAY[('received'::character varying)::text, ('processed'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: inbound_email_deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inbound_email_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inbound_email_deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inbound_email_deliveries_id_seq OWNED BY public.inbound_email_deliveries.id;


--
-- Name: installation_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.installation_states (
    id bigint NOT NULL,
    singleton boolean DEFAULT true NOT NULL,
    bootstrapped_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT installation_states_singleton CHECK (singleton)
);


--
-- Name: installation_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.installation_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: installation_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.installation_states_id_seq OWNED BY public.installation_states.id;


--
-- Name: integration_oauth_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_oauth_attempts (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    workspace_connector_id bigint NOT NULL,
    membership_id bigint NOT NULL,
    session_id bigint NOT NULL,
    state_digest character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    consumed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: integration_oauth_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.integration_oauth_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: integration_oauth_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.integration_oauth_attempts_id_seq OWNED BY public.integration_oauth_attempts.id;


--
-- Name: integration_user_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_user_connections (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    workspace_connector_id bigint NOT NULL,
    membership_id bigint NOT NULL,
    remote_user_id character varying NOT NULL,
    remote_workspace_id character varying NOT NULL,
    access_token text NOT NULL,
    refresh_token text,
    expires_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: integration_user_connections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.integration_user_connections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: integration_user_connections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.integration_user_connections_id_seq OWNED BY public.integration_user_connections.id;


--
-- Name: intercom_backfill_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_backfill_batches (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_backfill_run_id bigint NOT NULL,
    start_position integer NOT NULL,
    end_position integer NOT NULL,
    attempt_number integer DEFAULT 1 NOT NULL,
    status character varying NOT NULL,
    source_digest character varying NOT NULL,
    counts jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_definite_remote_id character varying,
    started_at timestamp(6) without time zone NOT NULL,
    completed_at timestamp(6) without time zone,
    expired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercom_backfill_batches_state CHECK ((((status)::text = ANY (ARRAY[('running'::character varying)::text, ('completed'::character varying)::text, ('blocked'::character varying)::text, ('failed'::character varying)::text])) AND (start_position >= 0) AND (end_position >= start_position) AND (attempt_number > 0) AND ((source_digest)::text ~ '^[0-9a-f]{64}$'::text) AND (octet_length((counts)::text) <= 8192) AND (jsonb_typeof(counts) = 'object'::text)))
);


--
-- Name: intercom_backfill_batches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_backfill_batches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_backfill_batches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_backfill_batches_id_seq OWNED BY public.intercom_backfill_batches.id;


--
-- Name: intercom_backfill_exceptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_backfill_exceptions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_backfill_manifest_id bigint NOT NULL,
    intercom_backfill_run_id bigint,
    source_identity_id bigint,
    remote_record_type character varying NOT NULL,
    remote_record_id character varying NOT NULL,
    source_digest character varying NOT NULL,
    exception_kind character varying NOT NULL,
    status character varying DEFAULT 'open'::character varying NOT NULL,
    recovery_action character varying NOT NULL,
    detail text NOT NULL,
    resolved_at timestamp(6) without time zone,
    expired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercom_backfill_exceptions_bounds CHECK ((((source_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((octet_length((remote_record_id)::text) >= 1) AND (octet_length((remote_record_id)::text) <= 255)) AND ((octet_length(detail) >= 1) AND (octet_length(detail) <= 500)))),
    CONSTRAINT intercom_backfill_exceptions_kind CHECK ((((remote_record_type)::text = ANY (ARRAY[('conversation'::character varying)::text, ('identity'::character varying)::text, ('attachment'::character varying)::text, ('field'::character varying)::text])) AND ((exception_kind)::text = ANY (ARRAY[('ambiguous_identity'::character varying)::text, ('source_changed'::character varying)::text, ('unsupported_field'::character varying)::text, ('attachment_rejected'::character varying)::text, ('attachment_unavailable'::character varying)::text, ('persistence_failed'::character varying)::text])) AND ((status)::text = ANY (ARRAY[('open'::character varying)::text, ('resolved'::character varying)::text])) AND ((recovery_action)::text = ANY (ARRAY[('review_identity'::character varying)::text, ('restart_preview'::character varying)::text, ('inspect_source'::character varying)::text, ('inspect_attachment'::character varying)::text, ('resume'::character varying)::text]))))
);


--
-- Name: intercom_backfill_exceptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_backfill_exceptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_backfill_exceptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_backfill_exceptions_id_seq OWNED BY public.intercom_backfill_exceptions.id;


--
-- Name: intercom_backfill_manifests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_backfill_manifests (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_connection_id bigint NOT NULL,
    created_by_membership_id bigint NOT NULL,
    created_by_user_id bigint NOT NULL,
    status character varying DEFAULT 'current'::character varying NOT NULL,
    source_digest character varying NOT NULL,
    discovery_records jsonb DEFAULT '[]'::jsonb NOT NULL,
    counts jsonb DEFAULT '{}'::jsonb NOT NULL,
    available_from timestamp(6) without time zone,
    available_to timestamp(6) without time zone,
    discovered_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    consumed_at timestamp(6) without time zone,
    expired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercom_backfill_manifests_bounds CHECK ((((source_digest)::text ~ '^[0-9a-f]{64}$'::text) AND (octet_length((discovery_records)::text) <= 262144) AND (octet_length((counts)::text) <= 8192) AND (jsonb_typeof(discovery_records) = 'array'::text) AND (jsonb_typeof(counts) = 'object'::text))),
    CONSTRAINT intercom_backfill_manifests_status CHECK (((status)::text = ANY (ARRAY[('current'::character varying)::text, ('consumed'::character varying)::text, ('stale'::character varying)::text])))
);


--
-- Name: intercom_backfill_manifests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_backfill_manifests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_backfill_manifests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_backfill_manifests_id_seq OWNED BY public.intercom_backfill_manifests.id;


--
-- Name: intercom_backfill_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_backfill_reports (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_backfill_run_id bigint NOT NULL,
    status character varying NOT NULL,
    counts jsonb NOT NULL,
    report_digest character varying NOT NULL,
    generated_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercom_backfill_reports_bounds CHECK ((((status)::text = ANY (ARRAY[('partial'::character varying)::text, ('complete'::character varying)::text])) AND ((report_digest)::text ~ '^[0-9a-f]{64}$'::text) AND (octet_length((counts)::text) <= 8192) AND (jsonb_typeof(counts) = 'object'::text)))
);


--
-- Name: intercom_backfill_reports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_backfill_reports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_backfill_reports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_backfill_reports_id_seq OWNED BY public.intercom_backfill_reports.id;


--
-- Name: intercom_backfill_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_backfill_runs (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_connection_id bigint NOT NULL,
    intercom_backfill_manifest_id bigint NOT NULL,
    confirmed_by_membership_id bigint NOT NULL,
    confirmed_by_user_id bigint NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    source_digest character varying NOT NULL,
    cursor_position integer DEFAULT 0 NOT NULL,
    counts jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_definite_remote_id character varying,
    last_definite_source_digest character varying,
    failure_code character varying,
    confirmed_at timestamp(6) without time zone NOT NULL,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    expired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercom_backfill_runs_bounds CHECK ((((source_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((last_definite_source_digest IS NULL) OR ((last_definite_source_digest)::text ~ '^[0-9a-f]{64}$'::text)) AND (octet_length((counts)::text) <= 8192) AND (jsonb_typeof(counts) = 'object'::text) AND ((failure_code IS NULL) OR ((failure_code)::text ~ '^[a-z][a-z0-9_]{0,99}$'::text)))),
    CONSTRAINT intercom_backfill_runs_state CHECK ((((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('blocked'::character varying)::text, ('failed'::character varying)::text, ('completed'::character varying)::text])) AND (cursor_position >= 0)))
);


--
-- Name: intercom_backfill_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_backfill_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_backfill_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_backfill_runs_id_seq OWNED BY public.intercom_backfill_runs.id;


--
-- Name: intercom_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_connections (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    name character varying NOT NULL,
    remote_workspace_id character varying NOT NULL,
    credential_key character varying NOT NULL,
    webhook_key character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    reconciliation_cursor character varying,
    last_reconciled_at timestamp(6) without time zone,
    last_error_code character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    help_center_sync_enabled boolean DEFAULT false NOT NULL
);


--
-- Name: intercom_connections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_connections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_connections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_connections_id_seq OWNED BY public.intercom_connections.id;


--
-- Name: intercom_conversation_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_conversation_links (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_connection_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    support_case_id bigint NOT NULL,
    remote_conversation_id character varying NOT NULL,
    remote_state character varying NOT NULL,
    remote_assignee_id character varying,
    remote_assignee_name character varying,
    source_digest character varying NOT NULL,
    remote_updated_at timestamp(6) without time zone NOT NULL,
    synced_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercom_conversation_links_digest CHECK (((source_digest)::text ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: intercom_conversation_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_conversation_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_conversation_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_conversation_links_id_seq OWNED BY public.intercom_conversation_links.id;


--
-- Name: intercom_drafts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_drafts (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    support_case_id bigint NOT NULL,
    intercom_conversation_link_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    updated_by_id bigint NOT NULL,
    body text NOT NULL,
    status character varying DEFAULT 'ready'::character varying NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    source_crew_artifact_id bigint,
    generated_body_digest character varying,
    generated_contract_result_state character varying,
    human_edited_by_membership_id bigint,
    human_edited_by_user_id bigint,
    human_edited_at timestamp(6) without time zone,
    CONSTRAINT intercom_drafts_body_size CHECK ((octet_length(body) <= 1048576)),
    CONSTRAINT intercom_drafts_contract_result CHECK (((generated_contract_result_state IS NULL) OR ((generated_contract_result_state)::text = ANY (ARRAY[('complete'::character varying)::text, ('blocked'::character varying)::text, ('needs_human'::character varying)::text])))),
    CONSTRAINT intercom_drafts_generated_digest CHECK (((generated_body_digest IS NULL) OR ((generated_body_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT intercom_drafts_provenance_shape CHECK ((((source_crew_artifact_id IS NULL) AND (generated_body_digest IS NULL) AND (generated_contract_result_state IS NULL) AND (human_edited_by_membership_id IS NULL) AND (human_edited_by_user_id IS NULL) AND (human_edited_at IS NULL)) OR ((source_crew_artifact_id IS NOT NULL) AND (generated_body_digest IS NOT NULL) AND (((human_edited_by_membership_id IS NULL) AND (human_edited_by_user_id IS NULL) AND (human_edited_at IS NULL)) OR ((human_edited_by_membership_id IS NOT NULL) AND (human_edited_by_user_id IS NOT NULL) AND (human_edited_at IS NOT NULL)))))),
    CONSTRAINT intercom_drafts_status CHECK (((status)::text = ANY (ARRAY[('ready'::character varying)::text, ('sending'::character varying)::text, ('sent'::character varying)::text])))
);


--
-- Name: intercom_drafts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_drafts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_drafts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_drafts_id_seq OWNED BY public.intercom_drafts.id;


--
-- Name: intercom_outbound_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_outbound_deliveries (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_draft_id bigint NOT NULL,
    intercom_connection_id bigint NOT NULL,
    intercom_conversation_link_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    conversation_message_id bigint,
    actor_membership_id bigint NOT NULL,
    actor_user_id bigint NOT NULL,
    idempotency_key character varying NOT NULL,
    remote_conversation_id character varying NOT NULL,
    source_part_id character varying NOT NULL,
    remote_part_id character varying,
    admin_id character varying NOT NULL,
    body text NOT NULL,
    status character varying DEFAULT 'sending'::character varying NOT NULL,
    failure_code character varying,
    started_at timestamp(6) without time zone NOT NULL,
    sent_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    source_crew_artifact_id bigint,
    generated_body_digest character varying,
    generated_contract_result_state character varying,
    human_edited_by_membership_id bigint,
    human_edited_by_user_id bigint,
    human_edited_at timestamp(6) without time zone,
    CONSTRAINT intercom_outbound_deliveries_body_size CHECK ((octet_length(body) <= 1048576)),
    CONSTRAINT intercom_outbound_deliveries_contract_result CHECK (((generated_contract_result_state IS NULL) OR ((generated_contract_result_state)::text = ANY (ARRAY[('complete'::character varying)::text, ('blocked'::character varying)::text, ('needs_human'::character varying)::text])))),
    CONSTRAINT intercom_outbound_deliveries_failure CHECK (((failure_code IS NULL) OR ((failure_code)::text = ANY (ARRAY[('configuration_error'::character varying)::text, ('remote_rejected'::character varying)::text, ('authorization_changed'::character varying)::text, ('unknown_outcome'::character varying)::text, ('confirmed_not_sent'::character varying)::text])))),
    CONSTRAINT intercom_outbound_deliveries_generated_digest CHECK (((generated_body_digest IS NULL) OR ((generated_body_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT intercom_outbound_deliveries_provenance_shape CHECK ((((source_crew_artifact_id IS NULL) AND (generated_body_digest IS NULL) AND (generated_contract_result_state IS NULL) AND (human_edited_by_membership_id IS NULL) AND (human_edited_by_user_id IS NULL) AND (human_edited_at IS NULL)) OR ((source_crew_artifact_id IS NOT NULL) AND (generated_body_digest IS NOT NULL) AND (((human_edited_by_membership_id IS NULL) AND (human_edited_by_user_id IS NULL) AND (human_edited_at IS NULL)) OR ((human_edited_by_membership_id IS NOT NULL) AND (human_edited_by_user_id IS NOT NULL) AND (human_edited_at IS NOT NULL)))))),
    CONSTRAINT intercom_outbound_deliveries_state CHECK (((((status)::text = 'sent'::text) AND (conversation_message_id IS NOT NULL) AND (remote_part_id IS NOT NULL) AND (sent_at IS NOT NULL) AND (failure_code IS NULL)) OR (((status)::text = ANY (ARRAY[('sending'::character varying)::text, ('failed'::character varying)::text, ('unknown'::character varying)::text])) AND (conversation_message_id IS NULL) AND (remote_part_id IS NULL) AND (sent_at IS NULL) AND ((((status)::text = 'sending'::text) AND (failure_code IS NULL)) OR (((status)::text = ANY (ARRAY[('failed'::character varying)::text, ('unknown'::character varying)::text])) AND (failure_code IS NOT NULL)))))),
    CONSTRAINT intercom_outbound_deliveries_status CHECK (((status)::text = ANY (ARRAY[('sending'::character varying)::text, ('sent'::character varying)::text, ('failed'::character varying)::text, ('unknown'::character varying)::text])))
);


--
-- Name: intercom_outbound_deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_outbound_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_outbound_deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_outbound_deliveries_id_seq OWNED BY public.intercom_outbound_deliveries.id;


--
-- Name: intercom_part_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_part_attachments (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_part_link_id bigint NOT NULL,
    stored_attachment_id bigint NOT NULL,
    remote_attachment_id character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercom_part_attachments_remote_id CHECK (((octet_length((remote_attachment_id)::text) >= 1) AND (octet_length((remote_attachment_id)::text) <= 255)))
);


--
-- Name: intercom_part_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_part_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_part_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_part_attachments_id_seq OWNED BY public.intercom_part_attachments.id;


--
-- Name: intercom_part_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_part_links (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_connection_id bigint NOT NULL,
    intercom_conversation_link_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    conversation_message_id bigint,
    remote_part_id character varying NOT NULL,
    part_type character varying NOT NULL,
    author_name character varying,
    body text NOT NULL,
    source_digest character varying NOT NULL,
    remote_created_at timestamp(6) without time zone NOT NULL,
    redacted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercom_part_links_digest CHECK (((source_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT intercom_part_links_message CHECK (((((part_type)::text = 'note'::text) AND (conversation_message_id IS NULL)) OR (((part_type)::text <> 'note'::text) AND (conversation_message_id IS NOT NULL)))),
    CONSTRAINT intercom_part_links_type CHECK (((part_type)::text = ANY (ARRAY[('contact_reply'::character varying)::text, ('admin_reply'::character varying)::text, ('note'::character varying)::text])))
);


--
-- Name: intercom_part_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_part_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_part_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_part_links_id_seq OWNED BY public.intercom_part_links.id;


--
-- Name: intercom_sync_operations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_sync_operations (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_connection_id bigint NOT NULL,
    intercom_conversation_link_id bigint NOT NULL,
    membership_id bigint NOT NULL,
    user_id bigint NOT NULL,
    operation_key character varying NOT NULL,
    operation_kind character varying NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    failure_code character varying,
    remote_object_id character varying,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_attempted_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercom_sync_operations_failure CHECK (((failure_code IS NULL) OR ((failure_code)::text = ANY (ARRAY[('configuration_error'::character varying)::text, ('remote_rejected'::character varying)::text, ('outcome_unknown'::character varying)::text])))),
    CONSTRAINT intercom_sync_operations_kind CHECK (((operation_kind)::text = ANY (ARRAY[('note'::character varying)::text, ('assign'::character varying)::text, ('tag'::character varying)::text, ('untag'::character varying)::text]))),
    CONSTRAINT intercom_sync_operations_payload CHECK ((octet_length((payload)::text) <= 65536)),
    CONSTRAINT intercom_sync_operations_state CHECK (((((status)::text = 'pending'::text) AND (attempt_count = 0) AND (last_attempted_at IS NULL) AND (failure_code IS NULL) AND (completed_at IS NULL)) OR (((status)::text = 'sending'::text) AND (attempt_count > 0) AND (last_attempted_at IS NOT NULL) AND (failure_code IS NULL) AND (completed_at IS NULL)) OR (((status)::text = 'completed'::text) AND (attempt_count > 0) AND (last_attempted_at IS NOT NULL) AND (failure_code IS NULL) AND (completed_at IS NOT NULL)) OR (((status)::text = ANY (ARRAY[('failed'::character varying)::text, ('unknown'::character varying)::text])) AND (attempt_count > 0) AND (last_attempted_at IS NOT NULL) AND (failure_code IS NOT NULL) AND (completed_at IS NULL)))),
    CONSTRAINT intercom_sync_operations_status CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('sending'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text, ('unknown'::character varying)::text])))
);


--
-- Name: intercom_sync_operations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_sync_operations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_sync_operations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_sync_operations_id_seq OWNED BY public.intercom_sync_operations.id;


--
-- Name: intercom_tag_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_tag_links (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_connection_id bigint NOT NULL,
    tag_id bigint NOT NULL,
    remote_tag_id character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: intercom_tag_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_tag_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_tag_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_tag_links_id_seq OWNED BY public.intercom_tag_links.id;


--
-- Name: intercom_webhook_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercom_webhook_deliveries (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_connection_id bigint NOT NULL,
    notification_id character varying NOT NULL,
    topic character varying NOT NULL,
    content_sha256 character varying NOT NULL,
    raw_payload bytea NOT NULL,
    status character varying DEFAULT 'received'::character varying NOT NULL,
    failure_code character varying,
    attempt_count integer DEFAULT 0 NOT NULL,
    received_at timestamp(6) without time zone NOT NULL,
    last_attempted_at timestamp(6) without time zone,
    processed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercom_webhook_deliveries_attempts CHECK ((((attempt_count = 0) AND (last_attempted_at IS NULL)) OR ((attempt_count > 0) AND (last_attempted_at IS NOT NULL)))),
    CONSTRAINT intercom_webhook_deliveries_digest CHECK (((content_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT intercom_webhook_deliveries_failure_code CHECK (((failure_code IS NULL) OR ((failure_code)::text = ANY (ARRAY[('invalid_payload'::character varying)::text, ('unsupported_topic'::character varying)::text, ('identity_ambiguous'::character varying)::text, ('remote_unavailable'::character varying)::text, ('persistence_error'::character varying)::text])))),
    CONSTRAINT intercom_webhook_deliveries_size CHECK ((octet_length(raw_payload) <= 1048576)),
    CONSTRAINT intercom_webhook_deliveries_state CHECK (((((status)::text = 'received'::text) AND (failure_code IS NULL) AND (processed_at IS NULL)) OR (((status)::text = 'processed'::text) AND (failure_code IS NULL) AND (processed_at IS NOT NULL)) OR (((status)::text = 'failed'::text) AND (failure_code IS NOT NULL) AND (processed_at IS NOT NULL)))),
    CONSTRAINT intercom_webhook_deliveries_status CHECK (((status)::text = ANY (ARRAY[('received'::character varying)::text, ('processed'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: intercom_webhook_deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercom_webhook_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercom_webhook_deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercom_webhook_deliveries_id_seq OWNED BY public.intercom_webhook_deliveries.id;


--
-- Name: knowledge_applicabilities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_applicabilities (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    knowledge_source_id bigint,
    intercom_connection_id bigint,
    all_products boolean DEFAULT true NOT NULL,
    all_connections boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT knowledge_applicabilities_owner CHECK (((knowledge_source_id IS NULL) <> (intercom_connection_id IS NULL)))
);


--
-- Name: knowledge_applicabilities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_applicabilities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_applicabilities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_applicabilities_id_seq OWNED BY public.knowledge_applicabilities.id;


--
-- Name: knowledge_applicability_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_applicability_connections (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    knowledge_applicability_id bigint NOT NULL,
    intercom_connection_id bigint NOT NULL
);


--
-- Name: knowledge_applicability_connections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_applicability_connections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_applicability_connections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_applicability_connections_id_seq OWNED BY public.knowledge_applicability_connections.id;


--
-- Name: knowledge_applicability_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_applicability_products (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    knowledge_applicability_id bigint NOT NULL,
    product_id bigint NOT NULL
);


--
-- Name: knowledge_applicability_products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_applicability_products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_applicability_products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_applicability_products_id_seq OWNED BY public.knowledge_applicability_products.id;


--
-- Name: knowledge_source_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_source_versions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    knowledge_source_id bigint NOT NULL,
    stored_attachment_id bigint,
    version_number integer NOT NULL,
    content text NOT NULL,
    content_sha256 character varying NOT NULL,
    retrieved_from_url character varying,
    retrieved_at timestamp(6) without time zone NOT NULL,
    source_updated_at timestamp(6) without time zone,
    expires_at timestamp(6) without time zone,
    created_by_membership_id bigint,
    created_by_user_id bigint,
    search_document tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, COALESCE(content, ''::text))) STORED,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    source_title character varying,
    CONSTRAINT knowledge_source_versions_actor CHECK ((((created_by_membership_id IS NULL) AND (created_by_user_id IS NULL)) OR ((created_by_membership_id IS NOT NULL) AND (created_by_user_id IS NOT NULL)))),
    CONSTRAINT knowledge_source_versions_content_size CHECK (((octet_length(content) >= 1) AND (octet_length(content) <= 1048576))),
    CONSTRAINT knowledge_source_versions_number CHECK ((version_number > 0)),
    CONSTRAINT knowledge_source_versions_sha256 CHECK (((content_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT knowledge_source_versions_url_length CHECK (((retrieved_from_url IS NULL) OR (((retrieved_from_url)::text ~ '^https://'::text) AND (length((retrieved_from_url)::text) <= 2048)))),
    CONSTRAINT knowledge_versions_title CHECK (((source_title IS NULL) OR ((length((source_title)::text) >= 1) AND (length((source_title)::text) <= 200))))
);


--
-- Name: knowledge_source_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_source_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_source_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_source_versions_id_seq OWNED BY public.knowledge_source_versions.id;


--
-- Name: knowledge_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_sources (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    source_kind character varying NOT NULL,
    source_key character varying NOT NULL,
    title character varying NOT NULL,
    canonical_url character varying,
    external_id character varying,
    current_version_id bigint,
    deleted_at timestamp(6) without time zone,
    deleted_by_membership_id bigint,
    deleted_by_user_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    intercom_connection_id bigint,
    notion_knowledge_connection_id bigint,
    CONSTRAINT knowledge_sources_deletion CHECK ((((deleted_at IS NULL) AND (deleted_by_membership_id IS NULL) AND (deleted_by_user_id IS NULL)) OR ((deleted_at IS NOT NULL) AND (deleted_by_membership_id IS NOT NULL) AND (deleted_by_user_id IS NOT NULL)))),
    CONSTRAINT knowledge_sources_identity CHECK ((((title)::text <> ''::text) AND (length((title)::text) <= 200) AND ((canonical_url IS NULL) OR (length((canonical_url)::text) <= 2048)) AND ((external_id IS NULL) OR (((external_id)::text <> ''::text) AND (length((external_id)::text) <= 500))))),
    CONSTRAINT knowledge_sources_key CHECK (((source_key)::text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'::text)),
    CONSTRAINT knowledge_sources_kind CHECK (((source_kind)::text = ANY ((ARRAY['manual'::character varying, 'url'::character varying, 'upload'::character varying, 'intercom_help_center'::character varying, 'notion_page'::character varying])::text[]))),
    CONSTRAINT knowledge_sources_locator CHECK (((((source_kind)::text = 'url'::text) AND ((canonical_url)::text ~ '^https://'::text) AND (external_id IS NULL)) OR (((source_kind)::text = ANY ((ARRAY['intercom_help_center'::character varying, 'notion_page'::character varying])::text[])) AND (external_id IS NOT NULL) AND (canonical_url IS NULL)) OR (((source_kind)::text = ANY ((ARRAY['manual'::character varying, 'upload'::character varying])::text[])) AND (canonical_url IS NULL) AND (external_id IS NULL)))),
    CONSTRAINT knowledge_sources_notion_origin CHECK (((notion_knowledge_connection_id IS NULL) OR (((source_kind)::text = 'notion_page'::text) AND (intercom_connection_id IS NULL)))),
    CONSTRAINT knowledge_sources_origin_kind CHECK (((intercom_connection_id IS NULL) OR ((source_kind)::text = 'intercom_help_center'::text)))
);


--
-- Name: knowledge_sources_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_sources_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_sources_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_sources_id_seq OWNED BY public.knowledge_sources.id;


--
-- Name: knowledge_sync_observations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_sync_observations (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    knowledge_source_id bigint NOT NULL,
    last_seen_pass_id bigint NOT NULL,
    observed_at timestamp(6) without time zone NOT NULL,
    missing_passes integer DEFAULT 0 NOT NULL,
    unavailable_at timestamp(6) without time zone,
    retired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT knowledge_sync_observations_state CHECK ((((missing_passes >= 0) AND (missing_passes <= 2)) AND (((missing_passes = 0) AND (unavailable_at IS NULL) AND (retired_at IS NULL)) OR ((missing_passes = 1) AND (unavailable_at IS NOT NULL) AND (retired_at IS NULL)) OR ((missing_passes = 2) AND (unavailable_at IS NOT NULL) AND (retired_at IS NOT NULL)))))
);


--
-- Name: knowledge_sync_observations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_sync_observations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_sync_observations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_sync_observations_id_seq OWNED BY public.knowledge_sync_observations.id;


--
-- Name: knowledge_sync_passes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_sync_passes (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    intercom_connection_id bigint,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    cursor character varying,
    page_count integer DEFAULT 0 NOT NULL,
    reconciliation_position bigint DEFAULT 0 NOT NULL,
    enumerated boolean DEFAULT false NOT NULL,
    failure_code character varying,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    notion_knowledge_connection_id bigint,
    frontier jsonb DEFAULT '[]'::jsonb NOT NULL,
    visited jsonb DEFAULT '[]'::jsonb NOT NULL,
    CONSTRAINT knowledge_sync_pass_origin CHECK (((intercom_connection_id IS NULL) <> (notion_knowledge_connection_id IS NULL))),
    CONSTRAINT knowledge_sync_passes_state CHECK ((((status)::text = ANY ((ARRAY['pending'::character varying, 'failed'::character varying, 'completed'::character varying])::text[])) AND ((page_count >= 0) AND (page_count <= 1000)) AND (reconciliation_position >= 0) AND ((cursor IS NULL) OR (octet_length((cursor)::text) <= 2048)) AND ((failure_code IS NULL) OR ((failure_code)::text ~ '^[a-z_]{1,64}$'::text)) AND (((status)::text = 'completed'::text) = (completed_at IS NOT NULL))))
);


--
-- Name: knowledge_sync_passes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_sync_passes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_sync_passes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_sync_passes_id_seq OWNED BY public.knowledge_sync_passes.id;


--
-- Name: memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memberships (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    user_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    role character varying NOT NULL,
    CONSTRAINT memberships_role CHECK (((role)::text = ANY (ARRAY[('owner'::character varying)::text, ('admin'::character varying)::text, ('manager'::character varying)::text, ('member'::character varying)::text, ('viewer'::character varying)::text])))
);


--
-- Name: memberships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memberships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memberships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memberships_id_seq OWNED BY public.memberships.id;


--
-- Name: memory_correction_proposals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_correction_proposals (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    memory_record_id bigint NOT NULL,
    proposed_by_membership_id bigint NOT NULL,
    proposed_by_user_id bigint NOT NULL,
    reviewed_by_membership_id bigint,
    reviewed_by_user_id bigint,
    published_memory_record_id bigint,
    proposal_key uuid DEFAULT gen_random_uuid() NOT NULL,
    content text NOT NULL,
    content_digest character varying NOT NULL,
    confidence numeric(4,3) NOT NULL,
    retention_policy character varying NOT NULL,
    retention_until timestamp(6) without time zone,
    status character varying DEFAULT 'proposed'::character varying NOT NULL,
    reviewed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT memory_corrections_content CHECK (((octet_length(content) >= 1) AND (octet_length(content) <= 32768) AND ((content_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((confidence >= 0.000) AND (confidence <= 1.000)))),
    CONSTRAINT memory_corrections_retention CHECK ((((retention_policy)::text = ANY (ARRAY[('indefinite'::character varying)::text, ('time_bound'::character varying)::text])) AND ((((retention_policy)::text = 'time_bound'::text) AND (retention_until IS NOT NULL)) OR (((retention_policy)::text = 'indefinite'::text) AND (retention_until IS NULL))))),
    CONSTRAINT memory_corrections_review CHECK (((((status)::text = 'proposed'::text) AND (reviewed_by_membership_id IS NULL) AND (reviewed_by_user_id IS NULL) AND (published_memory_record_id IS NULL) AND (reviewed_at IS NULL)) OR (((status)::text = 'accepted'::text) AND (reviewed_by_membership_id IS NOT NULL) AND (reviewed_by_user_id IS NOT NULL) AND (published_memory_record_id IS NOT NULL) AND (reviewed_at IS NOT NULL)) OR (((status)::text = 'rejected'::text) AND (reviewed_by_membership_id IS NOT NULL) AND (reviewed_by_user_id IS NOT NULL) AND (published_memory_record_id IS NULL) AND (reviewed_at IS NOT NULL))))
);


--
-- Name: memory_correction_proposals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memory_correction_proposals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memory_correction_proposals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memory_correction_proposals_id_seq OWNED BY public.memory_correction_proposals.id;


--
-- Name: memory_index_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_index_entries (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    memory_record_id bigint NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    external_document_id character varying,
    external_status character varying,
    failure_code character varying,
    last_attempted_at timestamp(6) without time zone,
    indexed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT memory_index_entries_document CHECK (((external_document_id IS NULL) OR ((octet_length((external_document_id)::text) >= 1) AND (octet_length((external_document_id)::text) <= 200)))),
    CONSTRAINT memory_index_entries_external_status CHECK (((external_status IS NULL) OR ((external_status)::text = ANY (ARRAY[('queued'::character varying)::text, ('extracting'::character varying)::text, ('chunking'::character varying)::text, ('embedding'::character varying)::text, ('done'::character varying)::text, ('failed'::character varying)::text])))),
    CONSTRAINT memory_index_entries_failure CHECK (((failure_code IS NULL) OR ((failure_code)::text ~ '^[a-z][a-z0-9_]{0,99}$'::text))),
    CONSTRAINT memory_index_entries_result CHECK (((((status)::text = 'pending'::text) AND (attempt_count = 0) AND (external_document_id IS NULL) AND (external_status IS NULL) AND (failure_code IS NULL) AND (last_attempted_at IS NULL) AND (indexed_at IS NULL)) OR (((status)::text = 'indexing'::text) AND (attempt_count > 0) AND (last_attempted_at IS NOT NULL) AND (indexed_at IS NULL)) OR (((status)::text = 'queued'::text) AND (attempt_count > 0) AND (external_document_id IS NOT NULL) AND (external_status IS NOT NULL) AND (failure_code IS NULL) AND (last_attempted_at IS NOT NULL) AND (indexed_at IS NULL)) OR (((status)::text = 'indexed'::text) AND (attempt_count > 0) AND (external_document_id IS NOT NULL) AND ((external_status)::text = 'done'::text) AND (failure_code IS NULL) AND (last_attempted_at IS NOT NULL) AND (indexed_at IS NOT NULL)) OR (((status)::text = ANY (ARRAY[('failed'::character varying)::text, ('unknown'::character varying)::text])) AND (attempt_count > 0) AND (failure_code IS NOT NULL) AND (last_attempted_at IS NOT NULL) AND (indexed_at IS NULL)))),
    CONSTRAINT memory_index_entries_state CHECK ((((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('indexing'::character varying)::text, ('queued'::character varying)::text, ('indexed'::character varying)::text, ('failed'::character varying)::text, ('unknown'::character varying)::text])) AND (attempt_count >= 0)))
);


--
-- Name: memory_index_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memory_index_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memory_index_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memory_index_entries_id_seq OWNED BY public.memory_index_entries.id;


--
-- Name: memory_proposals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_proposals (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    source_crew_artifact_id bigint NOT NULL,
    source_agent_profile_id bigint NOT NULL,
    account_id bigint,
    contact_id bigint,
    support_case_id bigint,
    reviewed_by_membership_id bigint,
    reviewed_by_user_id bigint,
    published_memory_record_id bigint,
    proposal_key uuid DEFAULT gen_random_uuid() NOT NULL,
    memory_type character varying NOT NULL,
    scope_kind character varying NOT NULL,
    topic character varying NOT NULL,
    content text NOT NULL,
    content_digest character varying NOT NULL,
    confidence numeric(4,3) NOT NULL,
    status character varying DEFAULT 'proposed'::character varying NOT NULL,
    reviewed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT memory_proposals_content CHECK ((((memory_type)::text = ANY (ARRAY[('semantic'::character varying)::text, ('profile'::character varying)::text])) AND ((scope_kind)::text = ANY (ARRAY[('account'::character varying)::text, ('contact'::character varying)::text, ('support_case'::character varying)::text])) AND ((octet_length((topic)::text) >= 1) AND (octet_length((topic)::text) <= 200)) AND ((octet_length(content) >= 1) AND (octet_length(content) <= 32768)) AND ((content_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((confidence >= 0.000) AND (confidence <= 1.000)))),
    CONSTRAINT memory_proposals_review CHECK (((((status)::text = 'proposed'::text) AND (reviewed_by_membership_id IS NULL) AND (reviewed_by_user_id IS NULL) AND (published_memory_record_id IS NULL) AND (reviewed_at IS NULL)) OR (((status)::text = 'accepted'::text) AND (reviewed_by_membership_id IS NOT NULL) AND (reviewed_by_user_id IS NOT NULL) AND (published_memory_record_id IS NOT NULL) AND (reviewed_at IS NOT NULL)) OR (((status)::text = 'rejected'::text) AND (reviewed_by_membership_id IS NOT NULL) AND (reviewed_by_user_id IS NOT NULL) AND (published_memory_record_id IS NULL) AND (reviewed_at IS NOT NULL)))),
    CONSTRAINT memory_proposals_scope CHECK (((((scope_kind)::text = 'account'::text) AND (account_id IS NOT NULL) AND (contact_id IS NULL) AND (support_case_id IS NULL)) OR (((scope_kind)::text = 'contact'::text) AND (account_id IS NULL) AND (contact_id IS NOT NULL) AND (support_case_id IS NULL)) OR (((scope_kind)::text = 'support_case'::text) AND (account_id IS NULL) AND (contact_id IS NULL) AND (support_case_id IS NOT NULL))))
);


--
-- Name: memory_proposals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memory_proposals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memory_proposals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memory_proposals_id_seq OWNED BY public.memory_proposals.id;


--
-- Name: memory_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_records (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    organization_id bigint,
    account_id bigint,
    contact_id bigint,
    support_case_id bigint,
    crew_template_id bigint,
    agent_profile_id bigint,
    user_id bigint,
    source_agent_profile_id bigint,
    source_membership_id bigint,
    source_user_id bigint,
    supersedes_memory_record_id bigint,
    memory_key uuid DEFAULT gen_random_uuid() NOT NULL,
    memory_type character varying NOT NULL,
    scope_kind character varying NOT NULL,
    topic character varying NOT NULL,
    content text NOT NULL,
    content_digest character varying NOT NULL,
    authority character varying NOT NULL,
    origin_kind character varying NOT NULL,
    source_reference character varying NOT NULL,
    source_digest character varying NOT NULL,
    observed_at timestamp(6) without time zone NOT NULL,
    valid_from timestamp(6) without time zone NOT NULL,
    valid_until timestamp(6) without time zone,
    confidence numeric(4,3) NOT NULL,
    retention_policy character varying NOT NULL,
    retention_until timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    capture_key character varying,
    CONSTRAINT memory_records_authority CHECK (((authority)::text = ANY (ARRAY[('inference'::character varying)::text, ('source_record'::character varying)::text, ('human_correction'::character varying)::text]))),
    CONSTRAINT memory_records_capture_key CHECK (((capture_key IS NULL) OR ((octet_length((capture_key)::text) >= 1) AND (octet_length((capture_key)::text) <= 200)))),
    CONSTRAINT memory_records_confidence CHECK (((confidence >= 0.000) AND (confidence <= 1.000))),
    CONSTRAINT memory_records_content CHECK (((octet_length((topic)::text) >= 1) AND (octet_length((topic)::text) <= 200) AND ((octet_length(content) >= 1) AND (octet_length(content) <= 32768)))),
    CONSTRAINT memory_records_correction_authority CHECK ((((authority)::text <> 'human_correction'::text) OR ((origin_kind)::text = 'human'::text))),
    CONSTRAINT memory_records_digests CHECK ((((content_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((source_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT memory_records_inference_authority CHECK ((((authority)::text <> 'inference'::text) OR ((origin_kind)::text = 'agent'::text))),
    CONSTRAINT memory_records_no_self_supersession CHECK (((supersedes_memory_record_id IS NULL) OR (supersedes_memory_record_id <> id))),
    CONSTRAINT memory_records_origin_kind CHECK (((origin_kind)::text = ANY (ARRAY[('system'::character varying)::text, ('agent'::character varying)::text, ('human'::character varying)::text]))),
    CONSTRAINT memory_records_origin_shape CHECK (((((origin_kind)::text = 'system'::text) AND (source_agent_profile_id IS NULL) AND (source_membership_id IS NULL) AND (source_user_id IS NULL)) OR (((origin_kind)::text = 'agent'::text) AND (source_agent_profile_id IS NOT NULL) AND (source_membership_id IS NULL) AND (source_user_id IS NULL)) OR (((origin_kind)::text = 'human'::text) AND (source_agent_profile_id IS NULL) AND (source_membership_id IS NOT NULL) AND (source_user_id IS NOT NULL)))),
    CONSTRAINT memory_records_procedural_authority CHECK ((((memory_type)::text <> 'procedural'::text) OR ((authority)::text = 'human_correction'::text))),
    CONSTRAINT memory_records_retention_policy CHECK (((retention_policy)::text = ANY (ARRAY[('indefinite'::character varying)::text, ('time_bound'::character varying)::text, ('source_lifetime'::character varying)::text]))),
    CONSTRAINT memory_records_retention_shape CHECK (((((retention_policy)::text = 'time_bound'::text) AND (retention_until IS NOT NULL) AND (retention_until > observed_at)) OR (((retention_policy)::text <> 'time_bound'::text) AND (retention_until IS NULL)))),
    CONSTRAINT memory_records_scope_kind CHECK (((scope_kind)::text = ANY (ARRAY[('organization'::character varying)::text, ('workspace'::character varying)::text, ('account'::character varying)::text, ('contact'::character varying)::text, ('support_case'::character varying)::text, ('crew'::character varying)::text, ('agent'::character varying)::text, ('user'::character varying)::text]))),
    CONSTRAINT memory_records_scope_shape CHECK (((((scope_kind)::text = 'organization'::text) AND (organization_id IS NOT NULL) AND (account_id IS NULL) AND (contact_id IS NULL) AND (support_case_id IS NULL) AND (crew_template_id IS NULL) AND (agent_profile_id IS NULL) AND (user_id IS NULL)) OR (((scope_kind)::text = 'workspace'::text) AND (organization_id IS NULL) AND (account_id IS NULL) AND (contact_id IS NULL) AND (support_case_id IS NULL) AND (crew_template_id IS NULL) AND (agent_profile_id IS NULL) AND (user_id IS NULL)) OR (((scope_kind)::text = 'account'::text) AND (organization_id IS NULL) AND (account_id IS NOT NULL) AND (contact_id IS NULL) AND (support_case_id IS NULL) AND (crew_template_id IS NULL) AND (agent_profile_id IS NULL) AND (user_id IS NULL)) OR (((scope_kind)::text = 'contact'::text) AND (organization_id IS NULL) AND (account_id IS NULL) AND (contact_id IS NOT NULL) AND (support_case_id IS NULL) AND (crew_template_id IS NULL) AND (agent_profile_id IS NULL) AND (user_id IS NULL)) OR (((scope_kind)::text = 'support_case'::text) AND (organization_id IS NULL) AND (account_id IS NULL) AND (contact_id IS NULL) AND (support_case_id IS NOT NULL) AND (crew_template_id IS NULL) AND (agent_profile_id IS NULL) AND (user_id IS NULL)) OR (((scope_kind)::text = 'crew'::text) AND (organization_id IS NULL) AND (account_id IS NULL) AND (contact_id IS NULL) AND (support_case_id IS NULL) AND (crew_template_id IS NOT NULL) AND (agent_profile_id IS NULL) AND (user_id IS NULL)) OR (((scope_kind)::text = 'agent'::text) AND (organization_id IS NULL) AND (account_id IS NULL) AND (contact_id IS NULL) AND (support_case_id IS NULL) AND (crew_template_id IS NULL) AND (agent_profile_id IS NOT NULL) AND (user_id IS NULL)) OR (((scope_kind)::text = 'user'::text) AND (organization_id IS NULL) AND (account_id IS NULL) AND (contact_id IS NULL) AND (support_case_id IS NULL) AND (crew_template_id IS NULL) AND (agent_profile_id IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT memory_records_source_authority CHECK ((((authority)::text <> 'source_record'::text) OR ((origin_kind)::text <> 'agent'::text))),
    CONSTRAINT memory_records_source_reference CHECK (((octet_length((source_reference)::text) >= 1) AND (octet_length((source_reference)::text) <= 2048))),
    CONSTRAINT memory_records_type CHECK (((memory_type)::text = ANY (ARRAY[('episodic'::character varying)::text, ('semantic'::character varying)::text, ('profile'::character varying)::text, ('procedural'::character varying)::text]))),
    CONSTRAINT memory_records_valid_time CHECK (((valid_until IS NULL) OR (valid_until > valid_from)))
);


--
-- Name: memory_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memory_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memory_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memory_records_id_seq OWNED BY public.memory_records.id;


--
-- Name: memory_tombstones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_tombstones (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    memory_record_id bigint NOT NULL,
    deleted_by_membership_id bigint NOT NULL,
    deleted_by_user_id bigint NOT NULL,
    reason character varying NOT NULL,
    index_status character varying DEFAULT 'pending'::character varying NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    failure_code character varying,
    last_attempted_at timestamp(6) without time zone,
    removed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT memory_tombstones_reason CHECK (((octet_length((reason)::text) >= 1) AND (octet_length((reason)::text) <= 500))),
    CONSTRAINT memory_tombstones_state CHECK (((((index_status)::text = 'pending'::text) AND (attempt_count = 0) AND (failure_code IS NULL) AND (last_attempted_at IS NULL) AND (removed_at IS NULL)) OR (((index_status)::text = 'removing'::text) AND (attempt_count > 0) AND (failure_code IS NULL) AND (last_attempted_at IS NOT NULL) AND (removed_at IS NULL)) OR (((index_status)::text = 'removed'::text) AND (attempt_count > 0) AND (failure_code IS NULL) AND (last_attempted_at IS NOT NULL) AND (removed_at IS NOT NULL)) OR (((index_status)::text = ANY (ARRAY[('failed'::character varying)::text, ('unknown'::character varying)::text])) AND (attempt_count > 0) AND (failure_code IS NOT NULL) AND (last_attempted_at IS NOT NULL) AND (removed_at IS NULL))))
);


--
-- Name: memory_tombstones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memory_tombstones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memory_tombstones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memory_tombstones_id_seq OWNED BY public.memory_tombstones.id;


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    recipient_membership_id bigint NOT NULL,
    source_audit_event_id bigint NOT NULL,
    category character varying NOT NULL,
    title character varying NOT NULL,
    path character varying NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    read_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT notifications_category CHECK (((category)::text = ANY (ARRAY[('assignment'::character varying)::text, ('review'::character varying)::text, ('sla'::character varying)::text, ('failure'::character varying)::text, ('blocked'::character varying)::text, ('completion'::character varying)::text]))),
    CONSTRAINT notifications_path CHECK ((((path)::text ~ '^/[^/]'::text) AND (octet_length((path)::text) <= 1000))),
    CONSTRAINT notifications_read_time CHECK (((read_at IS NULL) OR (read_at >= occurred_at))),
    CONSTRAINT notifications_title CHECK (((octet_length((title)::text) >= 1) AND (octet_length((title)::text) <= 200)))
);


--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notifications_id_seq OWNED BY public.notifications.id;


--
-- Name: notion_knowledge_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notion_knowledge_connections (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    workspace_connector_id bigint NOT NULL,
    name character varying NOT NULL,
    root_page_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT notion_knowledge_roots CHECK (((jsonb_typeof(root_page_ids) = 'array'::text) AND ((jsonb_array_length(root_page_ids) >= 1) AND (jsonb_array_length(root_page_ids) <= 20))))
);


--
-- Name: notion_knowledge_connections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notion_knowledge_connections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notion_knowledge_connections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notion_knowledge_connections_id_seq OWNED BY public.notion_knowledge_connections.id;


--
-- Name: oidc_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oidc_identities (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    issuer character varying NOT NULL,
    subject character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT oidc_identities_lengths CHECK (((length((issuer)::text) >= 1) AND (length((issuer)::text) <= 2048) AND ((length((subject)::text) >= 1) AND (length((subject)::text) <= 255))))
);


--
-- Name: oidc_identities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oidc_identities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oidc_identities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oidc_identities_id_seq OWNED BY public.oidc_identities.id;


--
-- Name: operational_checks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operational_checks (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    check_kind character varying NOT NULL,
    result character varying NOT NULL,
    result_code character varying NOT NULL,
    evidence_digest character varying NOT NULL,
    source_commit character varying NOT NULL,
    archive_format character varying,
    table_count bigint,
    record_count bigint,
    attachment_count bigint,
    memory_count bigint,
    recorded_by_membership_id bigint,
    recorded_by_user_id bigint,
    checked_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT operational_checks_actor CHECK (((recorded_by_membership_id IS NULL) = (recorded_by_user_id IS NULL))),
    CONSTRAINT operational_checks_archive_format CHECK (((archive_format IS NULL) OR ((octet_length((archive_format)::text) >= 1) AND (octet_length((archive_format)::text) <= 100)))),
    CONSTRAINT operational_checks_counts CHECK ((((table_count IS NULL) OR (table_count >= 0)) AND ((record_count IS NULL) OR (record_count >= 0)) AND ((attachment_count IS NULL) OR (attachment_count >= 0)) AND ((memory_count IS NULL) OR (memory_count >= 0)))),
    CONSTRAINT operational_checks_digests CHECK ((((evidence_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((source_commit)::text ~ '^[0-9a-f]{40}$'::text))),
    CONSTRAINT operational_checks_kind CHECK (((check_kind)::text = ANY (ARRAY[('archive_verification'::character varying)::text, ('backup_verification'::character varying)::text, ('restore_rehearsal'::character varying)::text, ('upgrade_preflight'::character varying)::text]))),
    CONSTRAINT operational_checks_result CHECK (((result)::text = ANY (ARRAY[('passed'::character varying)::text, ('failed'::character varying)::text, ('unavailable'::character varying)::text]))),
    CONSTRAINT operational_checks_result_code CHECK (((result_code)::text ~ '^[a-z][a-z0-9_]{0,99}$'::text))
);


--
-- Name: operational_checks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.operational_checks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: operational_checks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.operational_checks_id_seq OWNED BY public.operational_checks.id;


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations (
    id bigint NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: organizations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organizations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organizations_id_seq OWNED BY public.organizations.id;


--
-- Name: outbound_email_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbound_email_deliveries (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    email_draft_id bigint NOT NULL,
    shared_email_inbox_id bigint NOT NULL,
    email_thread_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    conversation_message_id bigint,
    actor_membership_id bigint NOT NULL,
    actor_user_id bigint NOT NULL,
    idempotency_key character varying NOT NULL,
    message_id character varying NOT NULL,
    in_reply_to_message_id character varying,
    from_address character varying NOT NULL,
    to_address character varying NOT NULL,
    subject character varying NOT NULL,
    body text NOT NULL,
    status character varying DEFAULT 'sending'::character varying NOT NULL,
    failure_code character varying,
    started_at timestamp(6) without time zone NOT NULL,
    sent_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    source_crew_artifact_id bigint,
    generated_body_digest character varying,
    generated_contract_result_state character varying,
    human_edited_by_membership_id bigint,
    human_edited_by_user_id bigint,
    human_edited_at timestamp(6) without time zone,
    CONSTRAINT outbound_email_deliveries_body_size CHECK ((octet_length(body) <= 1048576)),
    CONSTRAINT outbound_email_deliveries_contract_result CHECK (((generated_contract_result_state IS NULL) OR ((generated_contract_result_state)::text = ANY (ARRAY[('complete'::character varying)::text, ('blocked'::character varying)::text, ('needs_human'::character varying)::text])))),
    CONSTRAINT outbound_email_deliveries_generated_digest CHECK (((generated_body_digest IS NULL) OR ((generated_body_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT outbound_email_deliveries_provenance_shape CHECK ((((source_crew_artifact_id IS NULL) AND (generated_body_digest IS NULL) AND (generated_contract_result_state IS NULL) AND (human_edited_by_membership_id IS NULL) AND (human_edited_by_user_id IS NULL) AND (human_edited_at IS NULL)) OR ((source_crew_artifact_id IS NOT NULL) AND (generated_body_digest IS NOT NULL) AND (((human_edited_by_membership_id IS NULL) AND (human_edited_by_user_id IS NULL) AND (human_edited_at IS NULL)) OR ((human_edited_by_membership_id IS NOT NULL) AND (human_edited_by_user_id IS NOT NULL) AND (human_edited_at IS NOT NULL)))))),
    CONSTRAINT outbound_email_deliveries_state CHECK (((((status)::text = 'sent'::text) AND (conversation_message_id IS NOT NULL) AND (sent_at IS NOT NULL) AND (failure_code IS NULL)) OR (((status)::text = ANY (ARRAY[('sending'::character varying)::text, ('failed'::character varying)::text, ('unknown'::character varying)::text])) AND (conversation_message_id IS NULL) AND (sent_at IS NULL) AND ((((status)::text = 'sending'::text) AND (failure_code IS NULL)) OR (((status)::text = ANY (ARRAY[('failed'::character varying)::text, ('unknown'::character varying)::text])) AND (failure_code IS NOT NULL)))))),
    CONSTRAINT outbound_email_deliveries_status CHECK (((status)::text = ANY (ARRAY[('sending'::character varying)::text, ('sent'::character varying)::text, ('failed'::character varying)::text, ('unknown'::character varying)::text])))
);


--
-- Name: outbound_email_deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.outbound_email_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: outbound_email_deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.outbound_email_deliveries_id_seq OWNED BY public.outbound_email_deliveries.id;


--
-- Name: outbound_email_delivery_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbound_email_delivery_attachments (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    outbound_email_delivery_id bigint NOT NULL,
    stored_attachment_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: outbound_email_delivery_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.outbound_email_delivery_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: outbound_email_delivery_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.outbound_email_delivery_attachments_id_seq OWNED BY public.outbound_email_delivery_attachments.id;


--
-- Name: outbound_webhook_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbound_webhook_deliveries (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    outbound_webhook_endpoint_id bigint NOT NULL,
    notification_id bigint NOT NULL,
    event_key character varying NOT NULL,
    target_url text NOT NULL,
    credential_key character varying NOT NULL,
    payload text NOT NULL,
    payload_sha256 character varying NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    failure_code character varying,
    last_attempted_at timestamp(6) without time zone,
    delivered_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT outbound_webhook_deliveries_digest CHECK (((payload_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT outbound_webhook_deliveries_key CHECK (((event_key)::text ~ '^[0-9a-f-]{36}$'::text)),
    CONSTRAINT outbound_webhook_deliveries_state CHECK ((((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('sending'::character varying)::text, ('delivered'::character varying)::text, ('failed'::character varying)::text])) AND ((attempt_count >= 0) AND (attempt_count <= 5))))
);


--
-- Name: outbound_webhook_deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.outbound_webhook_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: outbound_webhook_deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.outbound_webhook_deliveries_id_seq OWNED BY public.outbound_webhook_deliveries.id;


--
-- Name: outbound_webhook_endpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbound_webhook_endpoints (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    name character varying NOT NULL,
    url text NOT NULL,
    credential_key character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    categories jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT outbound_webhooks_categories CHECK (((jsonb_typeof(categories) = 'array'::text) AND ((jsonb_array_length(categories) >= 1) AND (jsonb_array_length(categories) <= 6)))),
    CONSTRAINT outbound_webhooks_credential CHECK (((credential_key)::text ~ '^[a-z][a-z0-9_]{0,63}$'::text)),
    CONSTRAINT outbound_webhooks_name CHECK (((octet_length((name)::text) >= 1) AND (octet_length((name)::text) <= 100)))
);


--
-- Name: outbound_webhook_endpoints_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.outbound_webhook_endpoints_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: outbound_webhook_endpoints_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.outbound_webhook_endpoints_id_seq OWNED BY public.outbound_webhook_endpoints.id;


--
-- Name: personal_provider_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_provider_accounts (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    membership_id bigint NOT NULL,
    account_key uuid NOT NULL,
    state character varying DEFAULT 'starting'::character varying NOT NULL,
    expires_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT personal_accounts_state CHECK (((state)::text = ANY ((ARRAY['starting'::character varying, 'pending'::character varying, 'connected'::character varying, 'failed'::character varying, 'disconnected'::character varying])::text[])))
);


--
-- Name: personal_provider_accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.personal_provider_accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: personal_provider_accounts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.personal_provider_accounts_id_seq OWNED BY public.personal_provider_accounts.id;


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    name character varying(100) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT products_name_present CHECK ((length(TRIM(BOTH FROM name)) > 0))
);


--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;


--
-- Name: public_web_extractions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.public_web_extractions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    public_web_search_result_id bigint NOT NULL,
    request_key character varying NOT NULL,
    status character varying DEFAULT 'extracting'::character varying NOT NULL,
    source_url text NOT NULL,
    final_url text,
    content text,
    content_digest character varying,
    failure_code character varying,
    requested_by_membership_id bigint NOT NULL,
    requested_by_user_id bigint NOT NULL,
    retrieved_at timestamp(6) without time zone,
    source_updated_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT public_web_extractions_identity CHECK (((octet_length((request_key)::text) >= 1) AND (octet_length((request_key)::text) <= 128) AND ((status)::text = ANY (ARRAY[('extracting'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text])) AND ((octet_length(source_url) >= 9) AND (octet_length(source_url) <= 2048)) AND (source_url ~ '^https://'::text))),
    CONSTRAINT public_web_extractions_result CHECK (((((status)::text = 'extracting'::text) AND (final_url IS NULL) AND (content IS NULL) AND (content_digest IS NULL) AND (failure_code IS NULL) AND (retrieved_at IS NULL) AND (source_updated_at IS NULL)) OR (((status)::text = 'completed'::text) AND ((octet_length(final_url) >= 9) AND (octet_length(final_url) <= 2048)) AND (final_url ~ '^https://'::text) AND ((octet_length(content) >= 1) AND (octet_length(content) <= 1048576)) AND ((content_digest)::text ~ '^[0-9a-f]{64}$'::text) AND (failure_code IS NULL) AND (retrieved_at IS NOT NULL)) OR (((status)::text = 'failed'::text) AND (final_url IS NULL) AND (content IS NULL) AND (content_digest IS NULL) AND ((failure_code)::text ~ '^[a-z][a-z0-9_]{0,99}$'::text) AND (retrieved_at IS NULL) AND (source_updated_at IS NULL))))
);


--
-- Name: public_web_extractions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.public_web_extractions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: public_web_extractions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.public_web_extractions_id_seq OWNED BY public.public_web_extractions.id;


--
-- Name: public_web_search_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.public_web_search_results (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    public_web_search_id bigint NOT NULL,
    rank integer NOT NULL,
    citation_key character varying NOT NULL,
    title character varying NOT NULL,
    url text NOT NULL,
    excerpt text DEFAULT ''::text NOT NULL,
    published_at timestamp(6) without time zone,
    retrieved_at timestamp(6) without time zone NOT NULL,
    content_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT public_web_search_results_content CHECK (((rank >= 1) AND (rank <= 10) AND ((citation_key)::text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'::text) AND ((octet_length((title)::text) >= 1) AND (octet_length((title)::text) <= 500)) AND ((octet_length(url) >= 9) AND (octet_length(url) <= 2048)) AND (url ~ '^https://'::text) AND (octet_length(excerpt) <= 4000) AND ((content_digest)::text ~ '^[0-9a-f]{64}$'::text)))
);


--
-- Name: public_web_search_results_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.public_web_search_results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: public_web_search_results_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.public_web_search_results_id_seq OWNED BY public.public_web_search_results.id;


--
-- Name: public_web_searches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.public_web_searches (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    crew_task_id bigint NOT NULL,
    request_key character varying NOT NULL,
    query text NOT NULL,
    provider_key character varying,
    status character varying DEFAULT 'searching'::character varying NOT NULL,
    policy_decision character varying DEFAULT 'allowed'::character varying NOT NULL,
    cost_units bigint DEFAULT 0 NOT NULL,
    failure_code character varying,
    requested_by_membership_id bigint NOT NULL,
    requested_by_user_id bigint NOT NULL,
    retrieved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    usage_rate_version_id bigint,
    requested_provider_key character varying,
    CONSTRAINT public_web_searches_result CHECK (((((status)::text = 'searching'::text) AND (provider_key IS NULL) AND (failure_code IS NULL) AND (retrieved_at IS NULL)) OR (((status)::text = 'completed'::text) AND ((provider_key)::text ~ '^[a-z][a-z0-9_]{0,63}$'::text) AND (failure_code IS NULL) AND (retrieved_at IS NOT NULL)) OR (((status)::text = 'failed'::text) AND (provider_key IS NULL) AND ((failure_code)::text ~ '^[a-z][a-z0-9_]{0,99}$'::text) AND (retrieved_at IS NULL)))),
    CONSTRAINT public_web_searches_state CHECK (((octet_length((request_key)::text) >= 1) AND (octet_length((request_key)::text) <= 128) AND ((octet_length(query) >= 2) AND (octet_length(query) <= 500)) AND ((status)::text = ANY (ARRAY[('searching'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text])) AND ((policy_decision)::text = ANY (ARRAY[('allowed'::character varying)::text, ('redacted'::character varying)::text])) AND (cost_units >= 0))),
    CONSTRAINT search_provider_matches_request CHECK (((requested_provider_key IS NULL) OR (provider_key IS NULL) OR ((requested_provider_key)::text = (provider_key)::text))),
    CONSTRAINT search_requested_provider_key CHECK (((requested_provider_key)::text ~ '^[a-z][a-z0-9_]{0,63}$'::text))
);


--
-- Name: public_web_searches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.public_web_searches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: public_web_searches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.public_web_searches_id_seq OWNED BY public.public_web_searches.id;


--
-- Name: resolution_contract_families; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resolution_contract_families (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    family_key character varying NOT NULL,
    current_version_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT resolution_contract_families_key CHECK (((family_key)::text = ANY (ARRAY[('support_resolution'::character varying)::text, ('customer_success_intervention'::character varying)::text])))
);


--
-- Name: resolution_contract_families_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.resolution_contract_families_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: resolution_contract_families_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.resolution_contract_families_id_seq OWNED BY public.resolution_contract_families.id;


--
-- Name: resolution_contract_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resolution_contract_versions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    resolution_contract_family_id bigint NOT NULL,
    version_number integer NOT NULL,
    required_claim_categories jsonb DEFAULT '[]'::jsonb NOT NULL,
    evidence_freshness_days jsonb DEFAULT '{}'::jsonb NOT NULL,
    mandatory_review_checks jsonb DEFAULT '[]'::jsonb NOT NULL,
    execution_budget_units integer NOT NULL,
    missing_items_block boolean DEFAULT true NOT NULL,
    created_by_membership_id bigint,
    created_by_user_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT resolution_contract_versions_actor CHECK ((((created_by_membership_id IS NULL) AND (created_by_user_id IS NULL)) OR ((created_by_membership_id IS NOT NULL) AND (created_by_user_id IS NOT NULL)))),
    CONSTRAINT resolution_contract_versions_budget CHECK (((execution_budget_units >= 1) AND (execution_budget_units <= 20000000))),
    CONSTRAINT resolution_contract_versions_collections CHECK (((jsonb_typeof(required_claim_categories) = 'array'::text) AND ((jsonb_array_length(required_claim_categories) >= 1) AND (jsonb_array_length(required_claim_categories) <= 4)) AND (required_claim_categories <@ '["customer_account_fact", "product_technical_fact", "policy_entitlement", "promised_action_date"]'::jsonb) AND (jsonb_typeof(evidence_freshness_days) = 'object'::text) AND (evidence_freshness_days ?& ARRAY['knowledge'::text, 'conversation'::text, 'case'::text, 'account'::text, 'health_signal'::text, 'public_web'::text, 'memory'::text]) AND ((evidence_freshness_days - ARRAY['knowledge'::text, 'conversation'::text, 'case'::text, 'account'::text, 'health_signal'::text, 'public_web'::text, 'memory'::text]) = '{}'::jsonb) AND (jsonb_typeof((evidence_freshness_days -> 'knowledge'::text)) = 'number'::text) AND ((((evidence_freshness_days ->> 'knowledge'::text))::integer >= 1) AND (((evidence_freshness_days ->> 'knowledge'::text))::integer <= 3650)) AND (jsonb_typeof((evidence_freshness_days -> 'conversation'::text)) = 'number'::text) AND ((((evidence_freshness_days ->> 'conversation'::text))::integer >= 1) AND (((evidence_freshness_days ->> 'conversation'::text))::integer <= 3650)) AND (jsonb_typeof((evidence_freshness_days -> 'case'::text)) = 'number'::text) AND ((((evidence_freshness_days ->> 'case'::text))::integer >= 1) AND (((evidence_freshness_days ->> 'case'::text))::integer <= 3650)) AND (jsonb_typeof((evidence_freshness_days -> 'account'::text)) = 'number'::text) AND ((((evidence_freshness_days ->> 'account'::text))::integer >= 1) AND (((evidence_freshness_days ->> 'account'::text))::integer <= 3650)) AND (jsonb_typeof((evidence_freshness_days -> 'health_signal'::text)) = 'number'::text) AND ((((evidence_freshness_days ->> 'health_signal'::text))::integer >= 1) AND (((evidence_freshness_days ->> 'health_signal'::text))::integer <= 3650)) AND (jsonb_typeof((evidence_freshness_days -> 'public_web'::text)) = 'number'::text) AND ((((evidence_freshness_days ->> 'public_web'::text))::integer >= 1) AND (((evidence_freshness_days ->> 'public_web'::text))::integer <= 3650)) AND (jsonb_typeof((evidence_freshness_days -> 'memory'::text)) = 'number'::text) AND ((((evidence_freshness_days ->> 'memory'::text))::integer >= 1) AND (((evidence_freshness_days ->> 'memory'::text))::integer <= 3650)) AND (jsonb_typeof(mandatory_review_checks) = 'array'::text) AND ((jsonb_array_length(mandatory_review_checks) >= 1) AND (jsonb_array_length(mandatory_review_checks) <= 4)) AND (mandatory_review_checks <@ '["claims_grounded", "conflicts_resolved", "uncertainty_stated", "human_authority_preserved"]'::jsonb))),
    CONSTRAINT resolution_contract_versions_number CHECK ((version_number > 0))
);


--
-- Name: resolution_contract_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.resolution_contract_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: resolution_contract_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.resolution_contract_versions_id_seq OWNED BY public.resolution_contract_versions.id;


--
-- Name: runtime_installations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.runtime_installations (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    detection_key character varying NOT NULL,
    adapter_key character varying NOT NULL,
    protocol_version character varying NOT NULL,
    executable_path text NOT NULL,
    executable_version character varying NOT NULL,
    account_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    capabilities jsonb DEFAULT '[]'::jsonb NOT NULL,
    minimum_version character varying DEFAULT ''::character varying NOT NULL,
    maximum_version character varying DEFAULT ''::character varying NOT NULL,
    compatibility_status character varying NOT NULL,
    incompatibility_reason text DEFAULT ''::text NOT NULL,
    health_status character varying NOT NULL,
    checked_at timestamp(6) without time zone NOT NULL,
    approved boolean DEFAULT false NOT NULL,
    allowed_role_keys jsonb DEFAULT '[]'::jsonb NOT NULL,
    allowed_tools jsonb DEFAULT '[]'::jsonb NOT NULL,
    allowed_data_classes jsonb DEFAULT '[]'::jsonb NOT NULL,
    max_timeout_seconds integer DEFAULT 300 NOT NULL,
    max_steps integer DEFAULT 10 NOT NULL,
    max_tool_calls integer DEFAULT 20 NOT NULL,
    approved_by_membership_id bigint,
    approved_by_user_id bigint,
    approved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    profile_keys jsonb DEFAULT '["workspace_default"]'::jsonb NOT NULL,
    max_input_units bigint DEFAULT 100000 NOT NULL,
    max_output_units bigint DEFAULT 25000 NOT NULL,
    effective_model character varying DEFAULT 'runtime_default'::character varying NOT NULL,
    configuration_fingerprint character varying DEFAULT '0000000000000000000000000000000000000000000000000000000000000000'::character varying NOT NULL,
    runtime_test_status character varying DEFAULT 'untested'::character varying NOT NULL,
    runtime_test_failure_code character varying,
    runtime_tested_at timestamp(6) without time zone,
    runtime_tested_configuration_fingerprint character varying,
    runtime_test_input_units bigint DEFAULT 0 NOT NULL,
    runtime_test_output_units bigint DEFAULT 0 NOT NULL,
    runtime_test_usage_observed boolean DEFAULT false NOT NULL,
    execution_mode character varying DEFAULT 'legacy_unknown'::character varying NOT NULL,
    transport character varying DEFAULT 'legacy_unknown'::character varying NOT NULL,
    personal_provider_account_id bigint,
    CONSTRAINT runtime_installations_approval CHECK ((((approved = false) AND (approved_by_membership_id IS NULL) AND (approved_by_user_id IS NULL) AND (approved_at IS NULL)) OR ((approved = true) AND (approved_by_membership_id IS NOT NULL) AND (approved_by_user_id IS NOT NULL) AND (approved_at IS NOT NULL)))),
    CONSTRAINT runtime_installations_approval_requires_test CHECK (((approved = false) OR (((runtime_test_status)::text = 'passed'::text) AND ((runtime_tested_configuration_fingerprint)::text = (configuration_fingerprint)::text)))),
    CONSTRAINT runtime_installations_budgets CHECK (((max_timeout_seconds >= 30) AND (max_timeout_seconds <= 900) AND ((max_steps >= 1) AND (max_steps <= 20)) AND ((max_tool_calls >= 0) AND (max_tool_calls <= 50)))),
    CONSTRAINT runtime_installations_configuration_identity CHECK (((octet_length((effective_model)::text) >= 1) AND (octet_length((effective_model)::text) <= 200) AND ((effective_model)::text !~ '[\r\n]'::text) AND ((configuration_fingerprint)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT runtime_installations_detection_metadata CHECK (((jsonb_typeof(account_metadata) = 'object'::text) AND (jsonb_typeof(capabilities) = 'array'::text) AND (octet_length((account_metadata)::text) <= 8192) AND (jsonb_array_length(capabilities) <= 32) AND (octet_length((minimum_version)::text) <= 100) AND (octet_length((maximum_version)::text) <= 100) AND (octet_length(incompatibility_reason) <= 1000))),
    CONSTRAINT runtime_installations_executable CHECK (((executable_path ~~ '/%'::text) AND (octet_length(executable_path) <= 4096) AND ((executable_version)::text <> ''::text) AND (octet_length((executable_version)::text) <= 8192))),
    CONSTRAINT runtime_installations_execution_boundary CHECK ((((execution_mode)::text = ANY (ARRAY[('bounded'::character varying)::text, ('host_trusted'::character varying)::text, ('strong_isolated'::character varying)::text, ('legacy_unknown'::character varying)::text])) AND (((execution_mode)::text <> 'legacy_unknown'::text) OR (approved = false)))),
    CONSTRAINT runtime_installations_identity CHECK ((((detection_key)::text ~ '^[0-9a-f]{64}$'::text) AND ((adapter_key)::text ~ '^[a-z][a-z0-9_]{0,63}$'::text) AND ((protocol_version)::text ~ '^v[1-9][0-9]*$'::text))),
    CONSTRAINT runtime_installations_policy_arrays CHECK (((jsonb_typeof(allowed_role_keys) = 'array'::text) AND (jsonb_array_length(allowed_role_keys) <= 8) AND (jsonb_typeof(allowed_tools) = 'array'::text) AND (jsonb_array_length(allowed_tools) <= 9) AND (jsonb_typeof(allowed_data_classes) = 'array'::text) AND (jsonb_array_length(allowed_data_classes) <= 8))),
    CONSTRAINT runtime_installations_profiles CHECK (((jsonb_typeof(profile_keys) = 'array'::text) AND ((jsonb_array_length(profile_keys) >= 1) AND (jsonb_array_length(profile_keys) <= 3)) AND (profile_keys <@ '["workspace_default", "thorough", "fast"]'::jsonb))),
    CONSTRAINT runtime_installations_status CHECK ((((compatibility_status)::text = ANY (ARRAY[('compatible'::character varying)::text, ('warning'::character varying)::text, ('incompatible'::character varying)::text, ('unknown'::character varying)::text])) AND ((health_status)::text = ANY (ARRAY[('available'::character varying)::text, ('unhealthy'::character varying)::text, ('missing'::character varying)::text])))),
    CONSTRAINT runtime_installations_test_evidence CHECK ((((runtime_test_status)::text = ANY (ARRAY[('untested'::character varying)::text, ('passed'::character varying)::text, ('failed'::character varying)::text])) AND ((runtime_test_failure_code IS NULL) OR ((runtime_test_failure_code)::text ~ '^[a-z][a-z0-9_]{0,99}$'::text)) AND ((runtime_tested_configuration_fingerprint IS NULL) OR ((runtime_tested_configuration_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)) AND (runtime_test_input_units >= 0) AND (runtime_test_output_units >= 0))),
    CONSTRAINT runtime_installations_test_state CHECK (((((runtime_test_status)::text = 'untested'::text) AND (runtime_test_failure_code IS NULL) AND (runtime_tested_at IS NULL) AND (runtime_tested_configuration_fingerprint IS NULL) AND (runtime_test_input_units = 0) AND (runtime_test_output_units = 0) AND (runtime_test_usage_observed = false)) OR (((runtime_test_status)::text = 'passed'::text) AND (runtime_test_failure_code IS NULL) AND (runtime_tested_at IS NOT NULL) AND ((runtime_tested_configuration_fingerprint)::text = (configuration_fingerprint)::text)) OR (((runtime_test_status)::text = 'failed'::text) AND (runtime_test_failure_code IS NOT NULL) AND (runtime_tested_at IS NOT NULL) AND ((runtime_tested_configuration_fingerprint)::text = (configuration_fingerprint)::text)))),
    CONSTRAINT runtime_installations_transport CHECK ((((transport)::text = ANY (ARRAY[('built_in_https'::character varying)::text, ('managed_process'::character varying)::text, ('legacy_unknown'::character varying)::text])) AND (((transport)::text = 'legacy_unknown'::text) OR ((execution_mode)::text = 'legacy_unknown'::text) OR (((transport)::text = 'built_in_https'::text) AND ((execution_mode)::text = 'bounded'::text)) OR (((transport)::text = 'managed_process'::text) AND ((execution_mode)::text = ANY (ARRAY[('host_trusted'::character varying)::text, ('strong_isolated'::character varying)::text])))) AND (((transport)::text <> 'legacy_unknown'::text) OR (approved = false)) AND (((execution_mode)::text <> 'legacy_unknown'::text) OR (approved = false)))),
    CONSTRAINT runtime_installations_unit_budgets CHECK (((max_input_units >= 1) AND (max_input_units <= 10000000) AND ((max_output_units >= 1) AND (max_output_units <= 10000000))))
);


--
-- Name: runtime_installations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.runtime_installations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: runtime_installations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.runtime_installations_id_seq OWNED BY public.runtime_installations.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: service_calendar_holidays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_calendar_holidays (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    service_calendar_id bigint NOT NULL,
    date date NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: service_calendar_holidays_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.service_calendar_holidays_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: service_calendar_holidays_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.service_calendar_holidays_id_seq OWNED BY public.service_calendar_holidays.id;


--
-- Name: service_calendars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_calendars (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    name character varying NOT NULL,
    time_zone character varying NOT NULL,
    weekly_hours jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: service_calendars_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.service_calendars_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: service_calendars_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.service_calendars_id_seq OWNED BY public.service_calendars.id;


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    ip_address character varying,
    user_agent character varying,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    authentication_method character varying NOT NULL,
    revoked_at timestamp(6) without time zone,
    CONSTRAINT sessions_authentication_method CHECK (((authentication_method)::text = ANY (ARRAY[('local'::character varying)::text, ('oidc'::character varying)::text, ('break_glass'::character varying)::text])))
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: shared_email_inboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shared_email_inboxes (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    name character varying NOT NULL,
    email_address character varying NOT NULL,
    webhook_key character varying NOT NULL,
    credential_key character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: shared_email_inboxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.shared_email_inboxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: shared_email_inboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.shared_email_inboxes_id_seq OWNED BY public.shared_email_inboxes.id;


--
-- Name: sla_escalation_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sla_escalation_tasks (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    case_sla_id bigint NOT NULL,
    objective character varying NOT NULL,
    kind character varying NOT NULL,
    status character varying DEFAULT 'open'::character varying NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT sla_escalation_tasks_kind CHECK (((kind)::text = ANY (ARRAY[('warning'::character varying)::text, ('breach'::character varying)::text]))),
    CONSTRAINT sla_escalation_tasks_objective CHECK (((objective)::text = ANY (ARRAY[('first_response'::character varying)::text, ('resolution'::character varying)::text]))),
    CONSTRAINT sla_escalation_tasks_status CHECK (((status)::text = ANY (ARRAY[('open'::character varying)::text, ('completed'::character varying)::text])))
);


--
-- Name: sla_escalation_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sla_escalation_tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sla_escalation_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sla_escalation_tasks_id_seq OWNED BY public.sla_escalation_tasks.id;


--
-- Name: sla_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sla_policies (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    service_calendar_id bigint NOT NULL,
    name character varying NOT NULL,
    priority character varying NOT NULL,
    first_response_minutes integer NOT NULL,
    resolution_minutes integer NOT NULL,
    warning_percent integer DEFAULT 80 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT sla_policies_positive_targets CHECK (((first_response_minutes > 0) AND (resolution_minutes > 0))),
    CONSTRAINT sla_policies_priority CHECK (((priority)::text = ANY (ARRAY[('low'::character varying)::text, ('normal'::character varying)::text, ('high'::character varying)::text, ('urgent'::character varying)::text]))),
    CONSTRAINT sla_policies_warning_percent CHECK (((warning_percent >= 1) AND (warning_percent <= 99)))
);


--
-- Name: sla_policies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sla_policies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sla_policies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sla_policies_id_seq OWNED BY public.sla_policies.id;


--
-- Name: source_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_identities (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    entity_kind character varying NOT NULL,
    source_namespace character varying NOT NULL,
    source_record_type character varying NOT NULL,
    source_record_id character varying NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    account_id bigint,
    contact_id bigint,
    resolution_method character varying,
    resolved_by_id bigint,
    resolved_at timestamp(6) without time zone,
    retired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT source_identities_entity_kind CHECK (((entity_kind)::text = ANY (ARRAY[('account'::character varying)::text, ('contact'::character varying)::text]))),
    CONSTRAINT source_identities_resolution_method CHECK (((resolution_method IS NULL) OR ((resolution_method)::text = ANY (ARRAY[('created'::character varying)::text, ('deterministic'::character varying)::text, ('reviewed'::character varying)::text])))),
    CONSTRAINT source_identities_resolution_state CHECK (((((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('ambiguous'::character varying)::text])) AND (account_id IS NULL) AND (contact_id IS NULL) AND (resolution_method IS NULL) AND (resolved_by_id IS NULL) AND (resolved_at IS NULL)) OR (((status)::text = 'matched'::text) AND ((((entity_kind)::text = 'account'::text) AND (account_id IS NOT NULL) AND (contact_id IS NULL)) OR (((entity_kind)::text = 'contact'::text) AND (contact_id IS NOT NULL) AND (account_id IS NULL))) AND (resolution_method IS NOT NULL) AND (resolved_at IS NOT NULL)))),
    CONSTRAINT source_identities_status CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('ambiguous'::character varying)::text, ('matched'::character varying)::text])))
);


--
-- Name: source_identities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.source_identities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: source_identities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.source_identities_id_seq OWNED BY public.source_identities.id;


--
-- Name: source_identity_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_identity_keys (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    source_identity_id bigint NOT NULL,
    kind character varying NOT NULL,
    normalized_value character varying NOT NULL,
    retired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT source_identity_keys_kind CHECK (((kind)::text = ANY (ARRAY[('email'::character varying)::text, ('domain'::character varying)::text])))
);


--
-- Name: source_identity_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.source_identity_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: source_identity_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.source_identity_keys_id_seq OWNED BY public.source_identity_keys.id;


--
-- Name: stored_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stored_attachments (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    uploaded_by_membership_id bigint,
    uploaded_by_user_id bigint,
    source character varying NOT NULL,
    filename character varying NOT NULL,
    byte_size bigint NOT NULL,
    content_sha256 character varying NOT NULL,
    detected_content_type character varying NOT NULL,
    scan_status character varying NOT NULL,
    scan_result_code character varying,
    scanned_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT stored_attachments_actor CHECK (((((source)::text = ANY (ARRAY[('inbound_email'::character varying)::text, ('intercom_import'::character varying)::text])) AND (uploaded_by_membership_id IS NULL) AND (uploaded_by_user_id IS NULL)) OR (((source)::text = 'user_upload'::text) AND (uploaded_by_membership_id IS NOT NULL) AND (uploaded_by_user_id IS NOT NULL)))),
    CONSTRAINT stored_attachments_scan_state CHECK (((scan_result_code IS NOT NULL) AND ((scan_result_code)::text <> ''::text) AND ((((scan_status)::text = 'quarantined'::text) AND (scanned_at IS NULL)) OR (((scan_status)::text = ANY (ARRAY[('available'::character varying)::text, ('rejected'::character varying)::text])) AND (scanned_at IS NOT NULL))))),
    CONSTRAINT stored_attachments_scan_status CHECK (((scan_status)::text = ANY (ARRAY[('quarantined'::character varying)::text, ('available'::character varying)::text, ('rejected'::character varying)::text]))),
    CONSTRAINT stored_attachments_sha256 CHECK (((content_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT stored_attachments_size CHECK (((byte_size >= 1) AND (byte_size <= 5242880))),
    CONSTRAINT stored_attachments_source CHECK (((source)::text = ANY (ARRAY[('inbound_email'::character varying)::text, ('user_upload'::character varying)::text, ('intercom_import'::character varying)::text])))
);


--
-- Name: stored_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stored_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stored_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stored_attachments_id_seq OWNED BY public.stored_attachments.id;


--
-- Name: support_case_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_case_products (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    support_case_id bigint NOT NULL,
    product_id bigint NOT NULL
);


--
-- Name: support_case_products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.support_case_products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: support_case_products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.support_case_products_id_seq OWNED BY public.support_case_products.id;


--
-- Name: support_case_status_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_case_status_changes (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    support_case_id bigint NOT NULL,
    from_status character varying,
    to_status character varying NOT NULL,
    actor_kind character varying NOT NULL,
    actor_id bigint,
    source character varying NOT NULL,
    reason character varying NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT support_case_status_changes_actor CHECK ((((actor_kind)::text = ANY (ARRAY[('user'::character varying)::text, ('system'::character varying)::text])) AND ((((actor_kind)::text = 'user'::text) AND (actor_id IS NOT NULL)) OR (((actor_kind)::text = 'system'::text) AND (actor_id IS NULL))))),
    CONSTRAINT support_case_status_changes_from_status CHECK (((from_status IS NULL) OR ((from_status)::text = ANY (ARRAY[('new'::character varying)::text, ('triaged'::character varying)::text, ('investigating'::character varying)::text, ('waiting_customer'::character varying)::text, ('waiting_internal'::character varying)::text, ('draft_ready'::character varying)::text, ('awaiting_human_review'::character varying)::text, ('resolved'::character varying)::text, ('closed'::character varying)::text])))),
    CONSTRAINT support_case_status_changes_source CHECK (((source)::text = ANY (ARRAY[('web'::character varying)::text, ('job'::character varying)::text, ('task'::character varying)::text, ('runner'::character varying)::text, ('integration'::character varying)::text, ('system'::character varying)::text]))),
    CONSTRAINT support_case_status_changes_to_status CHECK (((to_status)::text = ANY (ARRAY[('new'::character varying)::text, ('triaged'::character varying)::text, ('investigating'::character varying)::text, ('waiting_customer'::character varying)::text, ('waiting_internal'::character varying)::text, ('draft_ready'::character varying)::text, ('awaiting_human_review'::character varying)::text, ('resolved'::character varying)::text, ('closed'::character varying)::text])))
);


--
-- Name: support_case_status_changes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.support_case_status_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: support_case_status_changes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.support_case_status_changes_id_seq OWNED BY public.support_case_status_changes.id;


--
-- Name: support_case_taggings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_case_taggings (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    support_case_id bigint NOT NULL,
    tag_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    source_intercom_connection_id bigint
);


--
-- Name: support_case_taggings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.support_case_taggings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: support_case_taggings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.support_case_taggings_id_seq OWNED BY public.support_case_taggings.id;


--
-- Name: support_cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_cases (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    assigned_membership_id bigint,
    status character varying DEFAULT 'new'::character varying NOT NULL,
    priority character varying DEFAULT 'normal'::character varying NOT NULL,
    status_changed_at timestamp(6) without time zone NOT NULL,
    resolved_at timestamp(6) without time zone,
    closed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT support_cases_priority CHECK (((priority)::text = ANY (ARRAY[('low'::character varying)::text, ('normal'::character varying)::text, ('high'::character varying)::text, ('urgent'::character varying)::text]))),
    CONSTRAINT support_cases_status CHECK (((status)::text = ANY (ARRAY[('new'::character varying)::text, ('triaged'::character varying)::text, ('investigating'::character varying)::text, ('waiting_customer'::character varying)::text, ('waiting_internal'::character varying)::text, ('draft_ready'::character varying)::text, ('awaiting_human_review'::character varying)::text, ('resolved'::character varying)::text, ('closed'::character varying)::text]))),
    CONSTRAINT support_cases_terminal_timestamps CHECK (((((status)::text = 'resolved'::text) AND (resolved_at IS NOT NULL) AND (closed_at IS NULL)) OR (((status)::text = 'closed'::text) AND (resolved_at IS NOT NULL) AND (closed_at IS NOT NULL)) OR (((status)::text <> ALL (ARRAY[('resolved'::character varying)::text, ('closed'::character varying)::text])) AND (resolved_at IS NULL) AND (closed_at IS NULL))))
);


--
-- Name: support_cases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.support_cases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: support_cases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.support_cases_id_seq OWNED BY public.support_cases.id;


--
-- Name: tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tags (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tags_id_seq OWNED BY public.tags.id;


--
-- Name: usage_cost_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_cost_snapshots (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    execution_run_id bigint,
    public_web_search_id bigint,
    applied_usage_rate_version_id bigint,
    status character varying NOT NULL,
    source character varying,
    currency character varying,
    amount_micros bigint,
    observed_input_units bigint,
    observed_output_units bigint,
    observed_search_units bigint,
    calculation_provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
    captured_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT usage_cost_snapshots_money_shape CHECK (((((status)::text = ANY (ARRAY[('complete'::character varying)::text, ('partial'::character varying)::text])) AND (source IS NOT NULL) AND (currency IS NOT NULL) AND (amount_micros IS NOT NULL)) OR (((status)::text = ANY (ARRAY[('unavailable'::character varying)::text, ('not_reported'::character varying)::text])) AND (source IS NULL) AND (currency IS NULL) AND (amount_micros IS NULL)))),
    CONSTRAINT usage_cost_snapshots_rate_source CHECK ((((source)::text <> 'configured_rate'::text) OR (applied_usage_rate_version_id IS NOT NULL))),
    CONSTRAINT usage_cost_snapshots_subject CHECK (((((execution_run_id IS NOT NULL))::integer + ((public_web_search_id IS NOT NULL))::integer) = 1)),
    CONSTRAINT usage_cost_snapshots_values CHECK ((((status)::text = ANY (ARRAY[('complete'::character varying)::text, ('partial'::character varying)::text, ('unavailable'::character varying)::text, ('not_reported'::character varying)::text])) AND ((source IS NULL) OR ((source)::text = ANY (ARRAY[('configured_rate'::character varying)::text, ('adapter_reported'::character varying)::text]))) AND ((currency IS NULL) OR ((currency)::text ~ '^[A-Z]{3}$'::text)) AND ((amount_micros IS NULL) OR (amount_micros >= 0)) AND ((observed_input_units IS NULL) OR (observed_input_units >= 0)) AND ((observed_output_units IS NULL) OR (observed_output_units >= 0)) AND ((observed_search_units IS NULL) OR (observed_search_units >= 0)) AND (jsonb_typeof(calculation_provenance) = 'object'::text) AND (octet_length((calculation_provenance)::text) <= 8192)))
);


--
-- Name: usage_cost_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.usage_cost_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: usage_cost_snapshots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.usage_cost_snapshots_id_seq OWNED BY public.usage_cost_snapshots.id;


--
-- Name: usage_rate_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_rate_settings (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    current_version_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: usage_rate_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.usage_rate_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: usage_rate_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.usage_rate_settings_id_seq OWNED BY public.usage_rate_settings.id;


--
-- Name: usage_rate_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_rate_versions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    usage_rate_setting_id bigint NOT NULL,
    version_number integer NOT NULL,
    currency character varying NOT NULL,
    input_rate_micros_per_million bigint,
    output_rate_micros_per_million bigint,
    search_rate_micros_per_million bigint,
    source_name character varying NOT NULL,
    created_by_membership_id bigint NOT NULL,
    created_by_user_id bigint NOT NULL,
    published_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT usage_rate_versions_identity CHECK ((((currency)::text ~ '^[A-Z]{3}$'::text) AND ((octet_length((source_name)::text) >= 1) AND (octet_length((source_name)::text) <= 100)))),
    CONSTRAINT usage_rate_versions_number CHECK ((version_number > 0)),
    CONSTRAINT usage_rate_versions_rates CHECK ((((input_rate_micros_per_million IS NOT NULL) OR (output_rate_micros_per_million IS NOT NULL) OR (search_rate_micros_per_million IS NOT NULL)) AND ((input_rate_micros_per_million IS NULL) OR ((input_rate_micros_per_million >= 0) AND (input_rate_micros_per_million <= '1000000000000'::bigint))) AND ((output_rate_micros_per_million IS NULL) OR ((output_rate_micros_per_million >= 0) AND (output_rate_micros_per_million <= '1000000000000'::bigint))) AND ((search_rate_micros_per_million IS NULL) OR ((search_rate_micros_per_million >= 0) AND (search_rate_micros_per_million <= '1000000000000'::bigint)))))
);


--
-- Name: usage_rate_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.usage_rate_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: usage_rate_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.usage_rate_versions_id_seq OWNED BY public.usage_rate_versions.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email_address character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    password_digest character varying NOT NULL,
    verified_at timestamp(6) without time zone,
    break_glass boolean DEFAULT false NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: workspace_connectors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_connectors (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    provider character varying NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    service_token text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    service_remote_workspace_id character varying,
    CONSTRAINT workspace_connectors_provider CHECK (((provider)::text = ANY ((ARRAY['intercom'::character varying, 'notion'::character varying])::text[])))
);


--
-- Name: workspace_connectors_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workspace_connectors_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workspace_connectors_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workspace_connectors_id_seq OWNED BY public.workspace_connectors.id;


--
-- Name: workspace_content_expiry_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_content_expiry_runs (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    cutoff_at timestamp(6) without time zone NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    expired_record_count integer DEFAULT 0 NOT NULL,
    failure_code character varying,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT workspace_content_expiry_runs_count CHECK ((expired_record_count >= 0)),
    CONSTRAINT workspace_content_expiry_runs_failure CHECK (((failure_code IS NULL) OR ((failure_code)::text ~ '^[a-z][a-z0-9_]{0,99}$'::text))),
    CONSTRAINT workspace_content_expiry_runs_status CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: workspace_content_expiry_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workspace_content_expiry_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workspace_content_expiry_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workspace_content_expiry_runs_id_seq OWNED BY public.workspace_content_expiry_runs.id;


--
-- Name: workspace_data_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_data_policies (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    content_retention_days integer,
    audit_retention_days integer,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    audit_expiry_status character varying,
    audit_expiry_cutoff_at timestamp(6) without time zone,
    audit_expired_event_count integer DEFAULT 0 NOT NULL,
    audit_expiry_failure_code character varying,
    audit_expiry_started_at timestamp(6) without time zone,
    audit_expiry_completed_at timestamp(6) without time zone,
    CONSTRAINT workspace_data_policies_audit_covers_content CHECK (((audit_retention_days IS NULL) OR (content_retention_days IS NULL) OR (audit_retention_days >= content_retention_days))),
    CONSTRAINT workspace_data_policies_audit_expiry_count CHECK ((audit_expired_event_count >= 0)),
    CONSTRAINT workspace_data_policies_audit_expiry_failure CHECK (((audit_expiry_failure_code IS NULL) OR ((audit_expiry_failure_code)::text ~ '^[a-z][a-z0-9_]{0,99}$'::text))),
    CONSTRAINT workspace_data_policies_audit_expiry_status CHECK (((audit_expiry_status IS NULL) OR ((audit_expiry_status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text])))),
    CONSTRAINT workspace_data_policies_audit_retention CHECK (((audit_retention_days IS NULL) OR (audit_retention_days = ANY (ARRAY[365, 730, 1825, 2555, 3650])))),
    CONSTRAINT workspace_data_policies_content_retention CHECK (((content_retention_days IS NULL) OR (content_retention_days = ANY (ARRAY[30, 90, 180, 365, 730, 1825]))))
);


--
-- Name: workspace_data_policies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workspace_data_policies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workspace_data_policies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workspace_data_policies_id_seq OWNED BY public.workspace_data_policies.id;


--
-- Name: workspace_deletion_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_deletion_requests (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    requested_by_id bigint NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    failure_code character varying,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT workspace_deletion_requests_attempts CHECK ((attempt_count >= 0)),
    CONSTRAINT workspace_deletion_requests_failure CHECK (((failure_code IS NULL) OR ((failure_code)::text ~ '^[a-z][a-z0-9_]{0,99}$'::text))),
    CONSTRAINT workspace_deletion_requests_status CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: workspace_deletion_requests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workspace_deletion_requests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workspace_deletion_requests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workspace_deletion_requests_id_seq OWNED BY public.workspace_deletion_requests.id;


--
-- Name: workspace_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_invitations (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    email_address character varying NOT NULL,
    role character varying NOT NULL,
    status character varying NOT NULL,
    token_nonce character varying NOT NULL,
    invited_by_id bigint NOT NULL,
    accepted_by_id bigint,
    expires_at timestamp(6) without time zone NOT NULL,
    accepted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT workspace_invitations_role CHECK (((role)::text = ANY (ARRAY[('owner'::character varying)::text, ('admin'::character varying)::text, ('manager'::character varying)::text, ('member'::character varying)::text, ('viewer'::character varying)::text]))),
    CONSTRAINT workspace_invitations_status CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('accepted'::character varying)::text, ('revoked'::character varying)::text, ('expired'::character varying)::text])))
);


--
-- Name: workspace_invitations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workspace_invitations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workspace_invitations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workspace_invitations_id_seq OWNED BY public.workspace_invitations.id;


--
-- Name: workspace_tombstones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_tombstones (
    id bigint NOT NULL,
    former_workspace_id bigint NOT NULL,
    organization_id bigint NOT NULL,
    deleted_by_id bigint NOT NULL,
    workspace_slug character varying NOT NULL,
    requested_at timestamp(6) without time zone NOT NULL,
    deleted_at timestamp(6) without time zone NOT NULL,
    record_count integer NOT NULL,
    attachment_count integer NOT NULL,
    memory_count integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT workspace_tombstones_counts CHECK (((record_count >= 0) AND (attachment_count >= 0) AND (memory_count >= 0)))
);


--
-- Name: workspace_tombstones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workspace_tombstones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workspace_tombstones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workspace_tombstones_id_seq OWNED BY public.workspace_tombstones.id;


--
-- Name: workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspaces (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    runner_key uuid DEFAULT gen_random_uuid() NOT NULL,
    deletion_requested_at timestamp(6) without time zone,
    web_search_provider_key character varying,
    CONSTRAINT workspace_search_provider_key CHECK (((web_search_provider_key)::text ~ '^[a-z][a-z0-9_]{0,63}$'::text))
);


--
-- Name: workspaces_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workspaces_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workspaces_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workspaces_id_seq OWNED BY public.workspaces.id;


--
-- Name: account_health_assessments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_assessments ALTER COLUMN id SET DEFAULT nextval('public.account_health_assessments_id_seq'::regclass);


--
-- Name: account_health_inputs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_inputs ALTER COLUMN id SET DEFAULT nextval('public.account_health_inputs_id_seq'::regclass);


--
-- Name: account_health_signals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_signals ALTER COLUMN id SET DEFAULT nextval('public.account_health_signals_id_seq'::regclass);


--
-- Name: account_merges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges ALTER COLUMN id SET DEFAULT nextval('public.account_merges_id_seq'::regclass);


--
-- Name: account_risk_investigations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_risk_investigations ALTER COLUMN id SET DEFAULT nextval('public.account_risk_investigations_id_seq'::regclass);


--
-- Name: accounts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts ALTER COLUMN id SET DEFAULT nextval('public.accounts_id_seq'::regclass);


--
-- Name: active_storage_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments ALTER COLUMN id SET DEFAULT nextval('public.active_storage_attachments_id_seq'::regclass);


--
-- Name: active_storage_blobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs ALTER COLUMN id SET DEFAULT nextval('public.active_storage_blobs_id_seq'::regclass);


--
-- Name: active_storage_variant_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records ALTER COLUMN id SET DEFAULT nextval('public.active_storage_variant_records_id_seq'::regclass);


--
-- Name: agent_profile_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profile_versions ALTER COLUMN id SET DEFAULT nextval('public.agent_profile_versions_id_seq'::regclass);


--
-- Name: agent_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profiles ALTER COLUMN id SET DEFAULT nextval('public.agent_profiles_id_seq'::regclass);


--
-- Name: audit_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ALTER COLUMN id SET DEFAULT nextval('public.audit_events_id_seq'::regclass);


--
-- Name: case_notes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_notes ALTER COLUMN id SET DEFAULT nextval('public.case_notes_id_seq'::regclass);


--
-- Name: case_slas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_slas ALTER COLUMN id SET DEFAULT nextval('public.case_slas_id_seq'::regclass);


--
-- Name: contact_merges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges ALTER COLUMN id SET DEFAULT nextval('public.contact_merges_id_seq'::regclass);


--
-- Name: contacts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts ALTER COLUMN id SET DEFAULT nextval('public.contacts_id_seq'::regclass);


--
-- Name: conversation_message_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_message_attachments ALTER COLUMN id SET DEFAULT nextval('public.conversation_message_attachments_id_seq'::regclass);


--
-- Name: conversation_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages ALTER COLUMN id SET DEFAULT nextval('public.conversation_messages_id_seq'::regclass);


--
-- Name: conversations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations ALTER COLUMN id SET DEFAULT nextval('public.conversations_id_seq'::regclass);


--
-- Name: crew_artifacts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts ALTER COLUMN id SET DEFAULT nextval('public.crew_artifacts_id_seq'::regclass);


--
-- Name: crew_task_dependencies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_dependencies ALTER COLUMN id SET DEFAULT nextval('public.crew_task_dependencies_id_seq'::regclass);


--
-- Name: crew_task_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events ALTER COLUMN id SET DEFAULT nextval('public.crew_task_events_id_seq'::regclass);


--
-- Name: crew_tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks ALTER COLUMN id SET DEFAULT nextval('public.crew_tasks_id_seq'::regclass);


--
-- Name: crew_templates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_templates ALTER COLUMN id SET DEFAULT nextval('public.crew_templates_id_seq'::regclass);


--
-- Name: customer_success_intervention_outcome_reviews id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_intervention_outcome_reviews ALTER COLUMN id SET DEFAULT nextval('public.customer_success_intervention_outcome_reviews_id_seq'::regclass);


--
-- Name: customer_success_interventions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions ALTER COLUMN id SET DEFAULT nextval('public.customer_success_interventions_id_seq'::regclass);


--
-- Name: email_draft_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_draft_attachments ALTER COLUMN id SET DEFAULT nextval('public.email_draft_attachments_id_seq'::regclass);


--
-- Name: email_drafts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts ALTER COLUMN id SET DEFAULT nextval('public.email_drafts_id_seq'::regclass);


--
-- Name: email_message_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_links ALTER COLUMN id SET DEFAULT nextval('public.email_message_links_id_seq'::regclass);


--
-- Name: email_threads id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_threads ALTER COLUMN id SET DEFAULT nextval('public.email_threads_id_seq'::regclass);


--
-- Name: execution_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_events ALTER COLUMN id SET DEFAULT nextval('public.execution_events_id_seq'::regclass);


--
-- Name: execution_memory_selections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_memory_selections ALTER COLUMN id SET DEFAULT nextval('public.execution_memory_selections_id_seq'::regclass);


--
-- Name: execution_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs ALTER COLUMN id SET DEFAULT nextval('public.execution_runs_id_seq'::regclass);


--
-- Name: governed_policy_previews id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_previews ALTER COLUMN id SET DEFAULT nextval('public.governed_policy_previews_id_seq'::regclass);


--
-- Name: governed_policy_proposals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals ALTER COLUMN id SET DEFAULT nextval('public.governed_policy_proposals_id_seq'::regclass);


--
-- Name: governed_policy_publications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_publications ALTER COLUMN id SET DEFAULT nextval('public.governed_policy_publications_id_seq'::regclass);


--
-- Name: governed_policy_subjects id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_subjects ALTER COLUMN id SET DEFAULT nextval('public.governed_policy_subjects_id_seq'::regclass);


--
-- Name: health_scorecard_backtests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_backtests ALTER COLUMN id SET DEFAULT nextval('public.health_scorecard_backtests_id_seq'::regclass);


--
-- Name: health_scorecard_design_turns id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_design_turns ALTER COLUMN id SET DEFAULT nextval('public.health_scorecard_design_turns_id_seq'::regclass);


--
-- Name: health_scorecard_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_versions ALTER COLUMN id SET DEFAULT nextval('public.health_scorecard_versions_id_seq'::regclass);


--
-- Name: health_scorecards id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecards ALTER COLUMN id SET DEFAULT nextval('public.health_scorecards_id_seq'::regclass);


--
-- Name: identity_match_candidates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates ALTER COLUMN id SET DEFAULT nextval('public.identity_match_candidates_id_seq'::regclass);


--
-- Name: inbound_email_deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbound_email_deliveries ALTER COLUMN id SET DEFAULT nextval('public.inbound_email_deliveries_id_seq'::regclass);


--
-- Name: installation_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.installation_states ALTER COLUMN id SET DEFAULT nextval('public.installation_states_id_seq'::regclass);


--
-- Name: integration_oauth_attempts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_oauth_attempts ALTER COLUMN id SET DEFAULT nextval('public.integration_oauth_attempts_id_seq'::regclass);


--
-- Name: integration_user_connections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_user_connections ALTER COLUMN id SET DEFAULT nextval('public.integration_user_connections_id_seq'::regclass);


--
-- Name: intercom_backfill_batches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_batches ALTER COLUMN id SET DEFAULT nextval('public.intercom_backfill_batches_id_seq'::regclass);


--
-- Name: intercom_backfill_exceptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_exceptions ALTER COLUMN id SET DEFAULT nextval('public.intercom_backfill_exceptions_id_seq'::regclass);


--
-- Name: intercom_backfill_manifests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_manifests ALTER COLUMN id SET DEFAULT nextval('public.intercom_backfill_manifests_id_seq'::regclass);


--
-- Name: intercom_backfill_reports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_reports ALTER COLUMN id SET DEFAULT nextval('public.intercom_backfill_reports_id_seq'::regclass);


--
-- Name: intercom_backfill_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_runs ALTER COLUMN id SET DEFAULT nextval('public.intercom_backfill_runs_id_seq'::regclass);


--
-- Name: intercom_connections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_connections ALTER COLUMN id SET DEFAULT nextval('public.intercom_connections_id_seq'::regclass);


--
-- Name: intercom_conversation_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_conversation_links ALTER COLUMN id SET DEFAULT nextval('public.intercom_conversation_links_id_seq'::regclass);


--
-- Name: intercom_drafts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_drafts ALTER COLUMN id SET DEFAULT nextval('public.intercom_drafts_id_seq'::regclass);


--
-- Name: intercom_outbound_deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries ALTER COLUMN id SET DEFAULT nextval('public.intercom_outbound_deliveries_id_seq'::regclass);


--
-- Name: intercom_part_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_attachments ALTER COLUMN id SET DEFAULT nextval('public.intercom_part_attachments_id_seq'::regclass);


--
-- Name: intercom_part_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_links ALTER COLUMN id SET DEFAULT nextval('public.intercom_part_links_id_seq'::regclass);


--
-- Name: intercom_sync_operations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_sync_operations ALTER COLUMN id SET DEFAULT nextval('public.intercom_sync_operations_id_seq'::regclass);


--
-- Name: intercom_tag_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_tag_links ALTER COLUMN id SET DEFAULT nextval('public.intercom_tag_links_id_seq'::regclass);


--
-- Name: intercom_webhook_deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_webhook_deliveries ALTER COLUMN id SET DEFAULT nextval('public.intercom_webhook_deliveries_id_seq'::regclass);


--
-- Name: knowledge_applicabilities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicabilities ALTER COLUMN id SET DEFAULT nextval('public.knowledge_applicabilities_id_seq'::regclass);


--
-- Name: knowledge_applicability_connections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicability_connections ALTER COLUMN id SET DEFAULT nextval('public.knowledge_applicability_connections_id_seq'::regclass);


--
-- Name: knowledge_applicability_products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicability_products ALTER COLUMN id SET DEFAULT nextval('public.knowledge_applicability_products_id_seq'::regclass);


--
-- Name: knowledge_source_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_versions ALTER COLUMN id SET DEFAULT nextval('public.knowledge_source_versions_id_seq'::regclass);


--
-- Name: knowledge_sources id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sources ALTER COLUMN id SET DEFAULT nextval('public.knowledge_sources_id_seq'::regclass);


--
-- Name: knowledge_sync_observations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_observations ALTER COLUMN id SET DEFAULT nextval('public.knowledge_sync_observations_id_seq'::regclass);


--
-- Name: knowledge_sync_passes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_passes ALTER COLUMN id SET DEFAULT nextval('public.knowledge_sync_passes_id_seq'::regclass);


--
-- Name: memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships ALTER COLUMN id SET DEFAULT nextval('public.memberships_id_seq'::regclass);


--
-- Name: memory_correction_proposals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_correction_proposals ALTER COLUMN id SET DEFAULT nextval('public.memory_correction_proposals_id_seq'::regclass);


--
-- Name: memory_index_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_index_entries ALTER COLUMN id SET DEFAULT nextval('public.memory_index_entries_id_seq'::regclass);


--
-- Name: memory_proposals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_proposals ALTER COLUMN id SET DEFAULT nextval('public.memory_proposals_id_seq'::regclass);


--
-- Name: memory_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records ALTER COLUMN id SET DEFAULT nextval('public.memory_records_id_seq'::regclass);


--
-- Name: memory_tombstones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_tombstones ALTER COLUMN id SET DEFAULT nextval('public.memory_tombstones_id_seq'::regclass);


--
-- Name: notifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications ALTER COLUMN id SET DEFAULT nextval('public.notifications_id_seq'::regclass);


--
-- Name: notion_knowledge_connections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notion_knowledge_connections ALTER COLUMN id SET DEFAULT nextval('public.notion_knowledge_connections_id_seq'::regclass);


--
-- Name: oidc_identities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_identities ALTER COLUMN id SET DEFAULT nextval('public.oidc_identities_id_seq'::regclass);


--
-- Name: operational_checks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_checks ALTER COLUMN id SET DEFAULT nextval('public.operational_checks_id_seq'::regclass);


--
-- Name: organizations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations ALTER COLUMN id SET DEFAULT nextval('public.organizations_id_seq'::regclass);


--
-- Name: outbound_email_deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries ALTER COLUMN id SET DEFAULT nextval('public.outbound_email_deliveries_id_seq'::regclass);


--
-- Name: outbound_email_delivery_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_delivery_attachments ALTER COLUMN id SET DEFAULT nextval('public.outbound_email_delivery_attachments_id_seq'::regclass);


--
-- Name: outbound_webhook_deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_webhook_deliveries ALTER COLUMN id SET DEFAULT nextval('public.outbound_webhook_deliveries_id_seq'::regclass);


--
-- Name: outbound_webhook_endpoints id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_webhook_endpoints ALTER COLUMN id SET DEFAULT nextval('public.outbound_webhook_endpoints_id_seq'::regclass);


--
-- Name: personal_provider_accounts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_provider_accounts ALTER COLUMN id SET DEFAULT nextval('public.personal_provider_accounts_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


--
-- Name: public_web_extractions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_extractions ALTER COLUMN id SET DEFAULT nextval('public.public_web_extractions_id_seq'::regclass);


--
-- Name: public_web_search_results id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_search_results ALTER COLUMN id SET DEFAULT nextval('public.public_web_search_results_id_seq'::regclass);


--
-- Name: public_web_searches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_searches ALTER COLUMN id SET DEFAULT nextval('public.public_web_searches_id_seq'::regclass);


--
-- Name: resolution_contract_families id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_contract_families ALTER COLUMN id SET DEFAULT nextval('public.resolution_contract_families_id_seq'::regclass);


--
-- Name: resolution_contract_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_contract_versions ALTER COLUMN id SET DEFAULT nextval('public.resolution_contract_versions_id_seq'::regclass);


--
-- Name: runtime_installations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runtime_installations ALTER COLUMN id SET DEFAULT nextval('public.runtime_installations_id_seq'::regclass);


--
-- Name: service_calendar_holidays id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_calendar_holidays ALTER COLUMN id SET DEFAULT nextval('public.service_calendar_holidays_id_seq'::regclass);


--
-- Name: service_calendars id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_calendars ALTER COLUMN id SET DEFAULT nextval('public.service_calendars_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: shared_email_inboxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shared_email_inboxes ALTER COLUMN id SET DEFAULT nextval('public.shared_email_inboxes_id_seq'::regclass);


--
-- Name: sla_escalation_tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_escalation_tasks ALTER COLUMN id SET DEFAULT nextval('public.sla_escalation_tasks_id_seq'::regclass);


--
-- Name: sla_policies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_policies ALTER COLUMN id SET DEFAULT nextval('public.sla_policies_id_seq'::regclass);


--
-- Name: source_identities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identities ALTER COLUMN id SET DEFAULT nextval('public.source_identities_id_seq'::regclass);


--
-- Name: source_identity_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identity_keys ALTER COLUMN id SET DEFAULT nextval('public.source_identity_keys_id_seq'::regclass);


--
-- Name: stored_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_attachments ALTER COLUMN id SET DEFAULT nextval('public.stored_attachments_id_seq'::regclass);


--
-- Name: support_case_products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_products ALTER COLUMN id SET DEFAULT nextval('public.support_case_products_id_seq'::regclass);


--
-- Name: support_case_status_changes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_status_changes ALTER COLUMN id SET DEFAULT nextval('public.support_case_status_changes_id_seq'::regclass);


--
-- Name: support_case_taggings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_taggings ALTER COLUMN id SET DEFAULT nextval('public.support_case_taggings_id_seq'::regclass);


--
-- Name: support_cases id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_cases ALTER COLUMN id SET DEFAULT nextval('public.support_cases_id_seq'::regclass);


--
-- Name: tags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags ALTER COLUMN id SET DEFAULT nextval('public.tags_id_seq'::regclass);


--
-- Name: usage_cost_snapshots id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_cost_snapshots ALTER COLUMN id SET DEFAULT nextval('public.usage_cost_snapshots_id_seq'::regclass);


--
-- Name: usage_rate_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_rate_settings ALTER COLUMN id SET DEFAULT nextval('public.usage_rate_settings_id_seq'::regclass);


--
-- Name: usage_rate_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_rate_versions ALTER COLUMN id SET DEFAULT nextval('public.usage_rate_versions_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: workspace_connectors id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_connectors ALTER COLUMN id SET DEFAULT nextval('public.workspace_connectors_id_seq'::regclass);


--
-- Name: workspace_content_expiry_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_content_expiry_runs ALTER COLUMN id SET DEFAULT nextval('public.workspace_content_expiry_runs_id_seq'::regclass);


--
-- Name: workspace_data_policies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_data_policies ALTER COLUMN id SET DEFAULT nextval('public.workspace_data_policies_id_seq'::regclass);


--
-- Name: workspace_deletion_requests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_deletion_requests ALTER COLUMN id SET DEFAULT nextval('public.workspace_deletion_requests_id_seq'::regclass);


--
-- Name: workspace_invitations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations ALTER COLUMN id SET DEFAULT nextval('public.workspace_invitations_id_seq'::regclass);


--
-- Name: workspace_tombstones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_tombstones ALTER COLUMN id SET DEFAULT nextval('public.workspace_tombstones_id_seq'::regclass);


--
-- Name: workspaces id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces ALTER COLUMN id SET DEFAULT nextval('public.workspaces_id_seq'::regclass);


--
-- Name: account_health_assessments account_health_assessments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_assessments
    ADD CONSTRAINT account_health_assessments_pkey PRIMARY KEY (id);


--
-- Name: account_health_inputs account_health_inputs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_inputs
    ADD CONSTRAINT account_health_inputs_pkey PRIMARY KEY (id);


--
-- Name: account_health_signals account_health_signals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_signals
    ADD CONSTRAINT account_health_signals_pkey PRIMARY KEY (id);


--
-- Name: account_merges account_merges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT account_merges_pkey PRIMARY KEY (id);


--
-- Name: account_risk_investigations account_risk_investigations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_risk_investigations
    ADD CONSTRAINT account_risk_investigations_pkey PRIMARY KEY (id);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: active_storage_attachments active_storage_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT active_storage_attachments_pkey PRIMARY KEY (id);


--
-- Name: active_storage_blobs active_storage_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT active_storage_blobs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_variant_records active_storage_variant_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT active_storage_variant_records_pkey PRIMARY KEY (id);


--
-- Name: agent_profile_versions agent_profile_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profile_versions
    ADD CONSTRAINT agent_profile_versions_pkey PRIMARY KEY (id);


--
-- Name: agent_profiles agent_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profiles
    ADD CONSTRAINT agent_profiles_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: case_notes case_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_notes
    ADD CONSTRAINT case_notes_pkey PRIMARY KEY (id);


--
-- Name: case_slas case_slas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_slas
    ADD CONSTRAINT case_slas_pkey PRIMARY KEY (id);


--
-- Name: contact_merges contact_merges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges
    ADD CONSTRAINT contact_merges_pkey PRIMARY KEY (id);


--
-- Name: contacts contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT contacts_pkey PRIMARY KEY (id);


--
-- Name: conversation_message_attachments conversation_message_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_message_attachments
    ADD CONSTRAINT conversation_message_attachments_pkey PRIMARY KEY (id);


--
-- Name: conversation_messages conversation_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages
    ADD CONSTRAINT conversation_messages_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: crew_artifacts crew_artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts
    ADD CONSTRAINT crew_artifacts_pkey PRIMARY KEY (id);


--
-- Name: crew_task_dependencies crew_task_dependencies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_dependencies
    ADD CONSTRAINT crew_task_dependencies_pkey PRIMARY KEY (id);


--
-- Name: crew_task_events crew_task_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT crew_task_events_pkey PRIMARY KEY (id);


--
-- Name: crew_tasks crew_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT crew_tasks_pkey PRIMARY KEY (id);


--
-- Name: crew_templates crew_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_templates
    ADD CONSTRAINT crew_templates_pkey PRIMARY KEY (id);


--
-- Name: customer_success_intervention_outcome_reviews customer_success_intervention_outcome_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_intervention_outcome_reviews
    ADD CONSTRAINT customer_success_intervention_outcome_reviews_pkey PRIMARY KEY (id);


--
-- Name: customer_success_interventions customer_success_interventions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT customer_success_interventions_pkey PRIMARY KEY (id);


--
-- Name: email_draft_attachments email_draft_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_draft_attachments
    ADD CONSTRAINT email_draft_attachments_pkey PRIMARY KEY (id);


--
-- Name: email_drafts email_drafts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT email_drafts_pkey PRIMARY KEY (id);


--
-- Name: email_message_links email_message_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_links
    ADD CONSTRAINT email_message_links_pkey PRIMARY KEY (id);


--
-- Name: email_threads email_threads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_threads
    ADD CONSTRAINT email_threads_pkey PRIMARY KEY (id);


--
-- Name: execution_events execution_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_events
    ADD CONSTRAINT execution_events_pkey PRIMARY KEY (id);


--
-- Name: execution_memory_selections execution_memory_selections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_memory_selections
    ADD CONSTRAINT execution_memory_selections_pkey PRIMARY KEY (id);


--
-- Name: execution_runs execution_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT execution_runs_pkey PRIMARY KEY (id);


--
-- Name: governed_policy_previews governed_policy_previews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_previews
    ADD CONSTRAINT governed_policy_previews_pkey PRIMARY KEY (id);


--
-- Name: governed_policy_proposals governed_policy_proposals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals
    ADD CONSTRAINT governed_policy_proposals_pkey PRIMARY KEY (id);


--
-- Name: governed_policy_publications governed_policy_publications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_publications
    ADD CONSTRAINT governed_policy_publications_pkey PRIMARY KEY (id);


--
-- Name: governed_policy_subjects governed_policy_subjects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_subjects
    ADD CONSTRAINT governed_policy_subjects_pkey PRIMARY KEY (id);


--
-- Name: health_scorecard_backtests health_scorecard_backtests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_backtests
    ADD CONSTRAINT health_scorecard_backtests_pkey PRIMARY KEY (id);


--
-- Name: health_scorecard_design_turns health_scorecard_design_turns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_design_turns
    ADD CONSTRAINT health_scorecard_design_turns_pkey PRIMARY KEY (id);


--
-- Name: health_scorecard_versions health_scorecard_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_versions
    ADD CONSTRAINT health_scorecard_versions_pkey PRIMARY KEY (id);


--
-- Name: health_scorecards health_scorecards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecards
    ADD CONSTRAINT health_scorecards_pkey PRIMARY KEY (id);


--
-- Name: identity_match_candidates identity_match_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates
    ADD CONSTRAINT identity_match_candidates_pkey PRIMARY KEY (id);


--
-- Name: inbound_email_deliveries inbound_email_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbound_email_deliveries
    ADD CONSTRAINT inbound_email_deliveries_pkey PRIMARY KEY (id);


--
-- Name: installation_states installation_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.installation_states
    ADD CONSTRAINT installation_states_pkey PRIMARY KEY (id);


--
-- Name: integration_oauth_attempts integration_oauth_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_oauth_attempts
    ADD CONSTRAINT integration_oauth_attempts_pkey PRIMARY KEY (id);


--
-- Name: integration_user_connections integration_user_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_user_connections
    ADD CONSTRAINT integration_user_connections_pkey PRIMARY KEY (id);


--
-- Name: intercom_backfill_batches intercom_backfill_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_batches
    ADD CONSTRAINT intercom_backfill_batches_pkey PRIMARY KEY (id);


--
-- Name: intercom_backfill_exceptions intercom_backfill_exceptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_exceptions
    ADD CONSTRAINT intercom_backfill_exceptions_pkey PRIMARY KEY (id);


--
-- Name: intercom_backfill_manifests intercom_backfill_manifests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_manifests
    ADD CONSTRAINT intercom_backfill_manifests_pkey PRIMARY KEY (id);


--
-- Name: intercom_backfill_reports intercom_backfill_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_reports
    ADD CONSTRAINT intercom_backfill_reports_pkey PRIMARY KEY (id);


--
-- Name: intercom_backfill_runs intercom_backfill_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_runs
    ADD CONSTRAINT intercom_backfill_runs_pkey PRIMARY KEY (id);


--
-- Name: intercom_connections intercom_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_connections
    ADD CONSTRAINT intercom_connections_pkey PRIMARY KEY (id);


--
-- Name: intercom_conversation_links intercom_conversation_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_conversation_links
    ADD CONSTRAINT intercom_conversation_links_pkey PRIMARY KEY (id);


--
-- Name: intercom_drafts intercom_drafts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_drafts
    ADD CONSTRAINT intercom_drafts_pkey PRIMARY KEY (id);


--
-- Name: intercom_outbound_deliveries intercom_outbound_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT intercom_outbound_deliveries_pkey PRIMARY KEY (id);


--
-- Name: intercom_part_attachments intercom_part_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_attachments
    ADD CONSTRAINT intercom_part_attachments_pkey PRIMARY KEY (id);


--
-- Name: intercom_part_links intercom_part_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_links
    ADD CONSTRAINT intercom_part_links_pkey PRIMARY KEY (id);


--
-- Name: intercom_sync_operations intercom_sync_operations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_sync_operations
    ADD CONSTRAINT intercom_sync_operations_pkey PRIMARY KEY (id);


--
-- Name: intercom_tag_links intercom_tag_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_tag_links
    ADD CONSTRAINT intercom_tag_links_pkey PRIMARY KEY (id);


--
-- Name: intercom_webhook_deliveries intercom_webhook_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_webhook_deliveries
    ADD CONSTRAINT intercom_webhook_deliveries_pkey PRIMARY KEY (id);


--
-- Name: knowledge_applicabilities knowledge_applicabilities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicabilities
    ADD CONSTRAINT knowledge_applicabilities_pkey PRIMARY KEY (id);


--
-- Name: knowledge_applicability_connections knowledge_applicability_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicability_connections
    ADD CONSTRAINT knowledge_applicability_connections_pkey PRIMARY KEY (id);


--
-- Name: knowledge_applicability_products knowledge_applicability_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicability_products
    ADD CONSTRAINT knowledge_applicability_products_pkey PRIMARY KEY (id);


--
-- Name: knowledge_source_versions knowledge_source_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_versions
    ADD CONSTRAINT knowledge_source_versions_pkey PRIMARY KEY (id);


--
-- Name: knowledge_sources knowledge_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sources
    ADD CONSTRAINT knowledge_sources_pkey PRIMARY KEY (id);


--
-- Name: knowledge_sync_observations knowledge_sync_observations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_observations
    ADD CONSTRAINT knowledge_sync_observations_pkey PRIMARY KEY (id);


--
-- Name: knowledge_sync_passes knowledge_sync_passes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_passes
    ADD CONSTRAINT knowledge_sync_passes_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);


--
-- Name: memory_correction_proposals memory_correction_proposals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_correction_proposals
    ADD CONSTRAINT memory_correction_proposals_pkey PRIMARY KEY (id);


--
-- Name: memory_index_entries memory_index_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_index_entries
    ADD CONSTRAINT memory_index_entries_pkey PRIMARY KEY (id);


--
-- Name: memory_proposals memory_proposals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_proposals
    ADD CONSTRAINT memory_proposals_pkey PRIMARY KEY (id);


--
-- Name: memory_records memory_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_pkey PRIMARY KEY (id);


--
-- Name: memory_tombstones memory_tombstones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_tombstones
    ADD CONSTRAINT memory_tombstones_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: notion_knowledge_connections notion_knowledge_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notion_knowledge_connections
    ADD CONSTRAINT notion_knowledge_connections_pkey PRIMARY KEY (id);


--
-- Name: oidc_identities oidc_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_identities
    ADD CONSTRAINT oidc_identities_pkey PRIMARY KEY (id);


--
-- Name: operational_checks operational_checks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_checks
    ADD CONSTRAINT operational_checks_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: outbound_email_deliveries outbound_email_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT outbound_email_deliveries_pkey PRIMARY KEY (id);


--
-- Name: outbound_email_delivery_attachments outbound_email_delivery_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_delivery_attachments
    ADD CONSTRAINT outbound_email_delivery_attachments_pkey PRIMARY KEY (id);


--
-- Name: outbound_webhook_deliveries outbound_webhook_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_webhook_deliveries
    ADD CONSTRAINT outbound_webhook_deliveries_pkey PRIMARY KEY (id);


--
-- Name: outbound_webhook_endpoints outbound_webhook_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_webhook_endpoints
    ADD CONSTRAINT outbound_webhook_endpoints_pkey PRIMARY KEY (id);


--
-- Name: personal_provider_accounts personal_provider_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_provider_accounts
    ADD CONSTRAINT personal_provider_accounts_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: public_web_extractions public_web_extractions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_extractions
    ADD CONSTRAINT public_web_extractions_pkey PRIMARY KEY (id);


--
-- Name: public_web_search_results public_web_search_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_search_results
    ADD CONSTRAINT public_web_search_results_pkey PRIMARY KEY (id);


--
-- Name: public_web_searches public_web_searches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_searches
    ADD CONSTRAINT public_web_searches_pkey PRIMARY KEY (id);


--
-- Name: resolution_contract_families resolution_contract_families_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_contract_families
    ADD CONSTRAINT resolution_contract_families_pkey PRIMARY KEY (id);


--
-- Name: resolution_contract_versions resolution_contract_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_contract_versions
    ADD CONSTRAINT resolution_contract_versions_pkey PRIMARY KEY (id);


--
-- Name: runtime_installations runtime_installations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runtime_installations
    ADD CONSTRAINT runtime_installations_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: service_calendar_holidays service_calendar_holidays_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_calendar_holidays
    ADD CONSTRAINT service_calendar_holidays_pkey PRIMARY KEY (id);


--
-- Name: service_calendars service_calendars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_calendars
    ADD CONSTRAINT service_calendars_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: shared_email_inboxes shared_email_inboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shared_email_inboxes
    ADD CONSTRAINT shared_email_inboxes_pkey PRIMARY KEY (id);


--
-- Name: sla_escalation_tasks sla_escalation_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_escalation_tasks
    ADD CONSTRAINT sla_escalation_tasks_pkey PRIMARY KEY (id);


--
-- Name: sla_policies sla_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT sla_policies_pkey PRIMARY KEY (id);


--
-- Name: source_identities source_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identities
    ADD CONSTRAINT source_identities_pkey PRIMARY KEY (id);


--
-- Name: source_identity_keys source_identity_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identity_keys
    ADD CONSTRAINT source_identity_keys_pkey PRIMARY KEY (id);


--
-- Name: stored_attachments stored_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_attachments
    ADD CONSTRAINT stored_attachments_pkey PRIMARY KEY (id);


--
-- Name: support_case_products support_case_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_products
    ADD CONSTRAINT support_case_products_pkey PRIMARY KEY (id);


--
-- Name: support_case_status_changes support_case_status_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_status_changes
    ADD CONSTRAINT support_case_status_changes_pkey PRIMARY KEY (id);


--
-- Name: support_case_taggings support_case_taggings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_taggings
    ADD CONSTRAINT support_case_taggings_pkey PRIMARY KEY (id);


--
-- Name: support_cases support_cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_cases
    ADD CONSTRAINT support_cases_pkey PRIMARY KEY (id);


--
-- Name: tags tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (id);


--
-- Name: usage_cost_snapshots usage_cost_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_cost_snapshots
    ADD CONSTRAINT usage_cost_snapshots_pkey PRIMARY KEY (id);


--
-- Name: usage_rate_settings usage_rate_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_rate_settings
    ADD CONSTRAINT usage_rate_settings_pkey PRIMARY KEY (id);


--
-- Name: usage_rate_versions usage_rate_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_rate_versions
    ADD CONSTRAINT usage_rate_versions_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: workspace_connectors workspace_connectors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_connectors
    ADD CONSTRAINT workspace_connectors_pkey PRIMARY KEY (id);


--
-- Name: workspace_content_expiry_runs workspace_content_expiry_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_content_expiry_runs
    ADD CONSTRAINT workspace_content_expiry_runs_pkey PRIMARY KEY (id);


--
-- Name: workspace_data_policies workspace_data_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_data_policies
    ADD CONSTRAINT workspace_data_policies_pkey PRIMARY KEY (id);


--
-- Name: workspace_deletion_requests workspace_deletion_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_deletion_requests
    ADD CONSTRAINT workspace_deletion_requests_pkey PRIMARY KEY (id);


--
-- Name: workspace_invitations workspace_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations
    ADD CONSTRAINT workspace_invitations_pkey PRIMARY KEY (id);


--
-- Name: workspace_tombstones workspace_tombstones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_tombstones
    ADD CONSTRAINT workspace_tombstones_pkey PRIMARY KEY (id);


--
-- Name: workspaces workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_pkey PRIMARY KEY (id);


--
-- Name: idx_on_email_draft_id_stored_attachment_id_e495be539b; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_email_draft_id_stored_attachment_id_e495be539b ON public.email_draft_attachments USING btree (email_draft_id, stored_attachment_id);


--
-- Name: idx_on_health_scorecard_id_version_number_9d7e490c0a; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_health_scorecard_id_version_number_9d7e490c0a ON public.health_scorecard_versions USING btree (health_scorecard_id, version_number);


--
-- Name: idx_on_health_scorecard_version_id_4459fbe5bb; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_health_scorecard_version_id_4459fbe5bb ON public.account_health_assessments USING btree (health_scorecard_version_id);


--
-- Name: idx_on_health_scorecard_version_id_created_at_fe6bf6a5dc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_health_scorecard_version_id_created_at_fe6bf6a5dc ON public.health_scorecard_backtests USING btree (health_scorecard_version_id, created_at);


--
-- Name: idx_on_intercom_connection_id_remote_part_id_61d69c288c; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_intercom_connection_id_remote_part_id_61d69c288c ON public.intercom_part_links USING btree (intercom_connection_id, remote_part_id);


--
-- Name: idx_on_intercom_connection_id_remote_tag_id_1e0b48db33; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_intercom_connection_id_remote_tag_id_1e0b48db33 ON public.intercom_tag_links USING btree (intercom_connection_id, remote_tag_id);


--
-- Name: idx_on_outbound_webhook_endpoint_id_ab9a3111dd; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_outbound_webhook_endpoint_id_ab9a3111dd ON public.outbound_webhook_deliveries USING btree (outbound_webhook_endpoint_id);


--
-- Name: idx_on_public_web_search_id_rank_c0f5f4d15a; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_public_web_search_id_rank_c0f5f4d15a ON public.public_web_search_results USING btree (public_web_search_id, rank);


--
-- Name: idx_on_public_web_search_id_url_74ee90fc19; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_public_web_search_id_url_74ee90fc19 ON public.public_web_search_results USING btree (public_web_search_id, url);


--
-- Name: idx_on_service_calendar_id_date_e0bbb87882; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_service_calendar_id_date_e0bbb87882 ON public.service_calendar_holidays USING btree (service_calendar_id, date);


--
-- Name: idx_on_shared_email_inbox_id_message_id_2a2dabc074; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_shared_email_inbox_id_message_id_2a2dabc074 ON public.email_message_links USING btree (shared_email_inbox_id, message_id);


--
-- Name: idx_on_shared_email_inbox_id_message_id_746c45d92b; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_shared_email_inbox_id_message_id_746c45d92b ON public.outbound_email_deliveries USING btree (shared_email_inbox_id, message_id);


--
-- Name: idx_on_workspace_connector_id_membership_id_30ca455257; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_connector_id_membership_id_30ca455257 ON public.integration_user_connections USING btree (workspace_connector_id, membership_id);


--
-- Name: idx_on_workspace_id_82898bf35b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_workspace_id_82898bf35b ON public.customer_success_intervention_outcome_reviews USING btree (workspace_id);


--
-- Name: idx_on_workspace_id_conversation_id_f80281e8e7; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_conversation_id_f80281e8e7 ON public.intercom_conversation_links USING btree (workspace_id, conversation_id);


--
-- Name: idx_on_workspace_id_created_at_06382063c0; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_workspace_id_created_at_06382063c0 ON public.workspace_content_expiry_runs USING btree (workspace_id, created_at);


--
-- Name: idx_on_workspace_id_memory_record_id_43806d3363; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_memory_record_id_43806d3363 ON public.memory_index_entries USING btree (workspace_id, memory_record_id);


--
-- Name: idx_on_workspace_id_remote_workspace_id_3dd6f8847c; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_remote_workspace_id_3dd6f8847c ON public.intercom_connections USING btree (workspace_id, remote_workspace_id);


--
-- Name: idx_on_workspace_id_source_agent_profile_id_94fb4dc643; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_workspace_id_source_agent_profile_id_94fb4dc643 ON public.memory_records USING btree (workspace_id, source_agent_profile_id) WHERE (source_agent_profile_id IS NOT NULL);


--
-- Name: idx_on_workspace_id_status_created_at_52affea5f4; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_workspace_id_status_created_at_52affea5f4 ON public.intercom_sync_operations USING btree (workspace_id, status, created_at);


--
-- Name: index_account_health_assessments_for_latest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_health_assessments_for_latest ON public.account_health_assessments USING btree (workspace_id, account_id, calculated_at);


--
-- Name: index_account_health_assessments_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_health_assessments_on_workspace_id ON public.account_health_assessments USING btree (workspace_id);


--
-- Name: index_account_health_assessments_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_account_health_assessments_on_workspace_id_and_id ON public.account_health_assessments USING btree (workspace_id, id);


--
-- Name: index_account_health_inputs_correction_target; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_account_health_inputs_correction_target ON public.account_health_inputs USING btree (workspace_id, account_id, input_key, id);


--
-- Name: index_account_health_inputs_for_latest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_health_inputs_for_latest ON public.account_health_inputs USING btree (workspace_id, account_id, input_key, observed_at);


--
-- Name: index_account_health_inputs_on_business_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_account_health_inputs_on_business_source ON public.account_health_inputs USING btree (workspace_id, source_namespace, source_key, input_key);


--
-- Name: index_account_health_inputs_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_health_inputs_on_workspace_id ON public.account_health_inputs USING btree (workspace_id);


--
-- Name: index_account_health_inputs_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_account_health_inputs_on_workspace_id_and_id ON public.account_health_inputs USING btree (workspace_id, id);


--
-- Name: index_account_health_signals_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_health_signals_on_workspace_id ON public.account_health_signals USING btree (workspace_id);


--
-- Name: index_account_health_signals_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_account_health_signals_on_workspace_id_and_id ON public.account_health_signals USING btree (workspace_id, id);


--
-- Name: index_account_health_signals_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_account_health_signals_unique ON public.account_health_signals USING btree (account_health_assessment_id, signal_key);


--
-- Name: index_account_merges_on_merged_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_merges_on_merged_by_id ON public.account_merges USING btree (merged_by_id);


--
-- Name: index_account_merges_on_unmerged_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_merges_on_unmerged_by_id ON public.account_merges USING btree (unmerged_by_id);


--
-- Name: index_account_merges_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_merges_on_workspace_id ON public.account_merges USING btree (workspace_id);


--
-- Name: index_account_risk_investigations_on_assessment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_account_risk_investigations_on_assessment ON public.account_risk_investigations USING btree (account_health_assessment_id);


--
-- Name: index_account_risk_investigations_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_risk_investigations_on_workspace_id ON public.account_risk_investigations USING btree (workspace_id);


--
-- Name: index_account_risk_investigations_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_account_risk_investigations_on_workspace_id_and_id ON public.account_risk_investigations USING btree (workspace_id, id);


--
-- Name: index_account_risk_investigations_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_risk_investigations_open ON public.account_risk_investigations USING btree (workspace_id, account_id, status);


--
-- Name: index_accounts_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_accounts_on_workspace_id ON public.accounts USING btree (workspace_id);


--
-- Name: index_accounts_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_accounts_on_workspace_id_and_id ON public.accounts USING btree (workspace_id, id);


--
-- Name: index_accounts_on_workspace_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_accounts_on_workspace_id_and_name ON public.accounts USING btree (workspace_id, name);


--
-- Name: index_active_account_merges_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_account_merges_on_source ON public.account_merges USING btree (workspace_id, source_id) WHERE (unmerged_at IS NULL);


--
-- Name: index_active_contact_merges_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_contact_merges_on_source ON public.contact_merges USING btree (workspace_id, source_id) WHERE (unmerged_at IS NULL);


--
-- Name: index_active_sla_policies_on_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_sla_policies_on_priority ON public.sla_policies USING btree (workspace_id, priority) WHERE active;


--
-- Name: index_active_storage_attachments_on_blob_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_blob_id ON public.active_storage_attachments USING btree (blob_id);


--
-- Name: index_active_storage_attachments_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_attachments_uniqueness ON public.active_storage_attachments USING btree (record_type, record_id, name, blob_id);


--
-- Name: index_active_storage_blobs_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_key ON public.active_storage_blobs USING btree (key);


--
-- Name: index_active_storage_stored_attachment_file; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_stored_attachment_file ON public.active_storage_attachments USING btree (record_type, record_id, name) WHERE ((record_type)::text = 'StoredAttachment'::text);


--
-- Name: index_active_storage_variant_records_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_variant_records_uniqueness ON public.active_storage_variant_records USING btree (blob_id, variation_digest);


--
-- Name: index_agent_profile_versions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_profile_versions_on_workspace_id ON public.agent_profile_versions USING btree (workspace_id);


--
-- Name: index_agent_profile_versions_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_profile_versions_on_workspace_id_and_id ON public.agent_profile_versions USING btree (workspace_id, id);


--
-- Name: index_agent_profiles_on_crew_template_id_and_role_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_profiles_on_crew_template_id_and_role_key ON public.agent_profiles USING btree (crew_template_id, role_key);


--
-- Name: index_agent_profiles_on_workspace_crew_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_profiles_on_workspace_crew_id ON public.agent_profiles USING btree (workspace_id, crew_template_id, id);


--
-- Name: index_agent_profiles_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_profiles_on_workspace_id ON public.agent_profiles USING btree (workspace_id);


--
-- Name: index_agent_profiles_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_profiles_on_workspace_id_and_id ON public.agent_profiles USING btree (workspace_id, id);


--
-- Name: index_agent_versions_on_profile_and_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_versions_on_profile_and_number ON public.agent_profile_versions USING btree (agent_profile_id, version_number);


--
-- Name: index_agent_versions_on_workspace_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_versions_on_workspace_profile_id ON public.agent_profile_versions USING btree (workspace_id, agent_profile_id, id);


--
-- Name: index_audit_events_for_retention; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_for_retention ON public.audit_events USING btree (workspace_id, expired_at, occurred_at);


--
-- Name: index_audit_events_on_action_and_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_action_and_occurred_at ON public.audit_events USING btree (action, occurred_at);


--
-- Name: index_audit_events_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_actor_id ON public.audit_events USING btree (actor_id);


--
-- Name: index_audit_events_on_actor_id_and_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_actor_id_and_occurred_at ON public.audit_events USING btree (actor_id, occurred_at);


--
-- Name: index_audit_events_on_subject_type_and_subject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_subject_type_and_subject_id ON public.audit_events USING btree (subject_type, subject_id);


--
-- Name: index_audit_events_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_workspace_id ON public.audit_events USING btree (workspace_id);


--
-- Name: index_audit_events_on_workspace_id_and_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_workspace_id_and_occurred_at ON public.audit_events USING btree (workspace_id, occurred_at);


--
-- Name: index_case_notes_on_support_case_id_and_created_at_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_notes_on_support_case_id_and_created_at_and_id ON public.case_notes USING btree (support_case_id, created_at, id);


--
-- Name: index_case_notes_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_notes_on_workspace_id ON public.case_notes USING btree (workspace_id);


--
-- Name: index_case_slas_on_first_response_clock; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_slas_on_first_response_clock ON public.case_slas USING btree (workspace_id, first_response_status, first_response_warning_at);


--
-- Name: index_case_slas_on_resolution_clock; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_slas_on_resolution_clock ON public.case_slas USING btree (workspace_id, resolution_status, resolution_warning_at);


--
-- Name: index_case_slas_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_slas_on_workspace_id ON public.case_slas USING btree (workspace_id);


--
-- Name: index_case_slas_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_case_slas_on_workspace_id_and_id ON public.case_slas USING btree (workspace_id, id);


--
-- Name: index_case_slas_on_workspace_id_and_support_case_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_case_slas_on_workspace_id_and_support_case_id ON public.case_slas USING btree (workspace_id, support_case_id);


--
-- Name: index_case_taggings_on_intercom_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_taggings_on_intercom_source ON public.support_case_taggings USING btree (workspace_id, source_intercom_connection_id);


--
-- Name: index_contact_merges_on_merged_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contact_merges_on_merged_by_id ON public.contact_merges USING btree (merged_by_id);


--
-- Name: index_contact_merges_on_unmerged_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contact_merges_on_unmerged_by_id ON public.contact_merges USING btree (unmerged_by_id);


--
-- Name: index_contact_merges_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contact_merges_on_workspace_id ON public.contact_merges USING btree (workspace_id);


--
-- Name: index_contacts_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_workspace_id ON public.contacts USING btree (workspace_id);


--
-- Name: index_contacts_on_workspace_id_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_workspace_id_and_account_id ON public.contacts USING btree (workspace_id, account_id);


--
-- Name: index_contacts_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contacts_on_workspace_id_and_id ON public.contacts USING btree (workspace_id, id);


--
-- Name: index_contacts_on_workspace_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_workspace_id_and_name ON public.contacts USING btree (workspace_id, name);


--
-- Name: index_conversation_message_attachments_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_message_attachments_on_workspace_id ON public.conversation_message_attachments USING btree (workspace_id);


--
-- Name: index_conversation_message_attachments_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_conversation_message_attachments_on_workspace_id_and_id ON public.conversation_message_attachments USING btree (workspace_id, id);


--
-- Name: index_conversation_messages_for_replies; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_conversation_messages_for_replies ON public.conversation_messages USING btree (workspace_id, conversation_id, id);


--
-- Name: index_conversation_messages_on_timeline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_messages_on_timeline ON public.conversation_messages USING btree (conversation_id, occurred_at, id);


--
-- Name: index_conversation_messages_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_messages_on_workspace_id ON public.conversation_messages USING btree (workspace_id);


--
-- Name: index_conversations_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_workspace_id ON public.conversations USING btree (workspace_id);


--
-- Name: index_conversations_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_conversations_on_workspace_id_and_id ON public.conversations USING btree (workspace_id, id);


--
-- Name: index_conversations_on_workspace_id_and_last_message_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_workspace_id_and_last_message_at ON public.conversations USING btree (workspace_id, last_message_at);


--
-- Name: index_crew_artifacts_on_artifact_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_artifacts_on_artifact_key ON public.crew_artifacts USING btree (artifact_key);


--
-- Name: index_crew_artifacts_on_execution_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_artifacts_on_execution_run_id ON public.crew_artifacts USING btree (execution_run_id);


--
-- Name: index_crew_artifacts_on_governed_policy_publication_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_artifacts_on_governed_policy_publication_id ON public.crew_artifacts USING btree (governed_policy_publication_id);


--
-- Name: index_crew_artifacts_on_resolution_contract_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_artifacts_on_resolution_contract_version_id ON public.crew_artifacts USING btree (resolution_contract_version_id);


--
-- Name: index_crew_artifacts_on_task_kind_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_artifacts_on_task_kind_version ON public.crew_artifacts USING btree (crew_task_id, artifact_kind, version_number);


--
-- Name: index_crew_artifacts_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_artifacts_on_workspace_id ON public.crew_artifacts USING btree (workspace_id);


--
-- Name: index_crew_artifacts_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_artifacts_on_workspace_id_and_id ON public.crew_artifacts USING btree (workspace_id, id);


--
-- Name: index_crew_task_dependencies_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_task_dependencies_on_workspace_id ON public.crew_task_dependencies USING btree (workspace_id);


--
-- Name: index_crew_task_dependencies_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_task_dependencies_unique ON public.crew_task_dependencies USING btree (crew_task_id, depends_on_task_id);


--
-- Name: index_crew_task_events_on_crew_task_id_and_sequence_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_task_events_on_crew_task_id_and_sequence_number ON public.crew_task_events USING btree (crew_task_id, sequence_number);


--
-- Name: index_crew_task_events_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_task_events_on_workspace_id ON public.crew_task_events USING btree (workspace_id);


--
-- Name: index_crew_task_events_on_workspace_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_task_events_on_workspace_task_id ON public.crew_task_events USING btree (workspace_id, crew_task_id, id);


--
-- Name: index_crew_tasks_frozen_policy_tuple; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_tasks_frozen_policy_tuple ON public.crew_tasks USING btree (workspace_id, id, governed_policy_publication_id, resolution_contract_version_id, assigned_agent_profile_version_id);


--
-- Name: index_crew_tasks_on_account_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_tasks_on_account_and_status ON public.crew_tasks USING btree (workspace_id, account_id, status);


--
-- Name: index_crew_tasks_on_case_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_tasks_on_case_and_status ON public.crew_tasks USING btree (workspace_id, support_case_id, status);


--
-- Name: index_crew_tasks_on_governed_policy_publication_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_tasks_on_governed_policy_publication_id ON public.crew_tasks USING btree (governed_policy_publication_id);


--
-- Name: index_crew_tasks_on_resolution_contract_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_tasks_on_resolution_contract_version_id ON public.crew_tasks USING btree (resolution_contract_version_id);


--
-- Name: index_crew_tasks_on_task_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_tasks_on_task_key ON public.crew_tasks USING btree (task_key);


--
-- Name: index_crew_tasks_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_tasks_on_workspace_id ON public.crew_tasks USING btree (workspace_id);


--
-- Name: index_crew_tasks_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_tasks_on_workspace_id_and_id ON public.crew_tasks USING btree (workspace_id, id);


--
-- Name: index_crew_templates_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_templates_on_workspace_id ON public.crew_templates USING btree (workspace_id);


--
-- Name: index_crew_templates_on_workspace_id_and_crew_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_templates_on_workspace_id_and_crew_kind ON public.crew_templates USING btree (workspace_id, crew_kind);


--
-- Name: index_crew_templates_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crew_templates_on_workspace_id_and_id ON public.crew_templates USING btree (workspace_id, id);


--
-- Name: index_cs_interventions_for_account_work; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_cs_interventions_for_account_work ON public.customer_success_interventions USING btree (workspace_id, account_id, status, target_on);


--
-- Name: index_cs_interventions_on_proposing_artifact; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_cs_interventions_on_proposing_artifact ON public.customer_success_interventions USING btree (proposing_crew_artifact_id);


--
-- Name: index_cs_interventions_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_cs_interventions_on_workspace_id_and_id ON public.customer_success_interventions USING btree (workspace_id, id);


--
-- Name: index_cs_outcome_reviews_on_intervention; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_cs_outcome_reviews_on_intervention ON public.customer_success_intervention_outcome_reviews USING btree (customer_success_intervention_id);


--
-- Name: index_cs_outcome_reviews_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_cs_outcome_reviews_on_workspace_id_and_id ON public.customer_success_intervention_outcome_reviews USING btree (workspace_id, id);


--
-- Name: index_current_source_identity_keys; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_current_source_identity_keys ON public.source_identity_keys USING btree (source_identity_id, kind, normalized_value) WHERE (retired_at IS NULL);


--
-- Name: index_customer_success_interventions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_customer_success_interventions_on_workspace_id ON public.customer_success_interventions USING btree (workspace_id);


--
-- Name: index_delivery_attachments_on_delivery_and_attachment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_delivery_attachments_on_delivery_and_attachment ON public.outbound_email_delivery_attachments USING btree (outbound_email_delivery_id, stored_attachment_id);


--
-- Name: index_delivery_attachments_on_workspace_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_delivery_attachments_on_workspace_and_id ON public.outbound_email_delivery_attachments USING btree (workspace_id, id);


--
-- Name: index_email_draft_attachments_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_email_draft_attachments_on_workspace_id ON public.email_draft_attachments USING btree (workspace_id);


--
-- Name: index_email_draft_attachments_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_draft_attachments_on_workspace_id_and_id ON public.email_draft_attachments USING btree (workspace_id, id);


--
-- Name: index_email_drafts_on_source_artifact; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_email_drafts_on_source_artifact ON public.email_drafts USING btree (workspace_id, source_crew_artifact_id);


--
-- Name: index_email_drafts_on_tenant_thread; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_drafts_on_tenant_thread ON public.email_drafts USING btree (workspace_id, id, email_thread_id, conversation_id);


--
-- Name: index_email_drafts_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_email_drafts_on_workspace_id ON public.email_drafts USING btree (workspace_id);


--
-- Name: index_email_drafts_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_drafts_on_workspace_id_and_id ON public.email_drafts USING btree (workspace_id, id);


--
-- Name: index_email_drafts_on_workspace_id_and_support_case_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_drafts_on_workspace_id_and_support_case_id ON public.email_drafts USING btree (workspace_id, support_case_id);


--
-- Name: index_email_message_links_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_email_message_links_on_workspace_id ON public.email_message_links USING btree (workspace_id);


--
-- Name: index_email_message_links_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_message_links_on_workspace_id_and_id ON public.email_message_links USING btree (workspace_id, id);


--
-- Name: index_email_threads_on_shared_email_inbox_id_and_thread_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_threads_on_shared_email_inbox_id_and_thread_key ON public.email_threads USING btree (shared_email_inbox_id, thread_key);


--
-- Name: index_email_threads_on_tenant_conversation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_threads_on_tenant_conversation ON public.email_threads USING btree (workspace_id, shared_email_inbox_id, id, conversation_id);


--
-- Name: index_email_threads_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_email_threads_on_workspace_id ON public.email_threads USING btree (workspace_id);


--
-- Name: index_email_threads_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_threads_on_workspace_id_and_id ON public.email_threads USING btree (workspace_id, id);


--
-- Name: index_email_threads_on_workspace_thread_conversation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_threads_on_workspace_thread_conversation ON public.email_threads USING btree (workspace_id, id, conversation_id);


--
-- Name: index_execution_events_on_event_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_events_on_event_key ON public.execution_events USING btree (event_key);


--
-- Name: index_execution_events_on_execution_run_id_and_sequence_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_events_on_execution_run_id_and_sequence_number ON public.execution_events USING btree (execution_run_id, sequence_number);


--
-- Name: index_execution_events_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_execution_events_on_workspace_id ON public.execution_events USING btree (workspace_id);


--
-- Name: index_execution_events_on_workspace_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_events_on_workspace_run_id ON public.execution_events USING btree (workspace_id, execution_run_id, id);


--
-- Name: index_execution_memory_selections_on_execution_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_execution_memory_selections_on_execution_run_id ON public.execution_memory_selections USING btree (execution_run_id);


--
-- Name: index_execution_memory_selections_on_execution_run_id_and_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_memory_selections_on_execution_run_id_and_rank ON public.execution_memory_selections USING btree (execution_run_id, rank);


--
-- Name: index_execution_memory_selections_on_memory_record_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_execution_memory_selections_on_memory_record_id ON public.execution_memory_selections USING btree (memory_record_id);


--
-- Name: index_execution_memory_selections_on_run_and_memory; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_memory_selections_on_run_and_memory ON public.execution_memory_selections USING btree (execution_run_id, memory_record_id);


--
-- Name: index_execution_memory_selections_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_execution_memory_selections_on_workspace_id ON public.execution_memory_selections USING btree (workspace_id);


--
-- Name: index_execution_memory_selections_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_memory_selections_on_workspace_id_and_id ON public.execution_memory_selections USING btree (workspace_id, id);


--
-- Name: index_execution_runs_frozen_policy_tuple; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_runs_frozen_policy_tuple ON public.execution_runs USING btree (workspace_id, id, crew_task_id, governed_policy_publication_id, resolution_contract_version_id);


--
-- Name: index_execution_runs_on_crew_task_id_and_attempt_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_runs_on_crew_task_id_and_attempt_number ON public.execution_runs USING btree (crew_task_id, attempt_number);


--
-- Name: index_execution_runs_on_governed_policy_publication_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_execution_runs_on_governed_policy_publication_id ON public.execution_runs USING btree (governed_policy_publication_id);


--
-- Name: index_execution_runs_on_input_artifact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_execution_runs_on_input_artifact_id ON public.execution_runs USING btree (input_artifact_id);


--
-- Name: index_execution_runs_on_resolution_contract_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_execution_runs_on_resolution_contract_version_id ON public.execution_runs USING btree (resolution_contract_version_id);


--
-- Name: index_execution_runs_on_run_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_runs_on_run_key ON public.execution_runs USING btree (run_key);


--
-- Name: index_execution_runs_on_runtime_installation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_execution_runs_on_runtime_installation_id ON public.execution_runs USING btree (runtime_installation_id);


--
-- Name: index_execution_runs_on_usage_rate_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_execution_runs_on_usage_rate_version_id ON public.execution_runs USING btree (usage_rate_version_id);


--
-- Name: index_execution_runs_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_execution_runs_on_workspace_id ON public.execution_runs USING btree (workspace_id);


--
-- Name: index_execution_runs_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_runs_on_workspace_id_and_id ON public.execution_runs USING btree (workspace_id, id);


--
-- Name: index_execution_runs_on_workspace_id_and_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_runs_on_workspace_id_and_request_key ON public.execution_runs USING btree (workspace_id, request_key);


--
-- Name: index_execution_runs_on_workspace_id_task; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_execution_runs_on_workspace_id_task ON public.execution_runs USING btree (workspace_id, id, crew_task_id);


--
-- Name: index_governed_policy_previews_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_governed_policy_previews_on_workspace_id_and_id ON public.governed_policy_previews USING btree (workspace_id, id);


--
-- Name: index_governed_policy_previews_stable; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_governed_policy_previews_stable ON public.governed_policy_previews USING btree (governed_policy_proposal_id, evidence_digest, results_digest);


--
-- Name: index_governed_policy_proposals_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_governed_policy_proposals_on_workspace_id_and_id ON public.governed_policy_proposals USING btree (workspace_id, id);


--
-- Name: index_governed_policy_publications_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_governed_policy_publications_on_workspace_id_and_id ON public.governed_policy_publications USING btree (workspace_id, id);


--
-- Name: index_governed_policy_subjects_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_governed_policy_subjects_on_workspace_id_and_id ON public.governed_policy_subjects USING btree (workspace_id, id);


--
-- Name: index_health_scorecard_backtests_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_health_scorecard_backtests_on_workspace_id ON public.health_scorecard_backtests USING btree (workspace_id);


--
-- Name: index_health_scorecard_backtests_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_health_scorecard_backtests_on_workspace_id_and_id ON public.health_scorecard_backtests USING btree (workspace_id, id);


--
-- Name: index_health_scorecard_design_turns_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_health_scorecard_design_turns_on_workspace_id ON public.health_scorecard_design_turns USING btree (workspace_id);


--
-- Name: index_health_scorecard_design_turns_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_health_scorecard_design_turns_on_workspace_id_and_id ON public.health_scorecard_design_turns USING btree (workspace_id, id);


--
-- Name: index_health_scorecard_versions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_health_scorecard_versions_on_workspace_id ON public.health_scorecard_versions USING btree (workspace_id);


--
-- Name: index_health_scorecard_versions_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_health_scorecard_versions_on_workspace_id_and_id ON public.health_scorecard_versions USING btree (workspace_id, id);


--
-- Name: index_health_scorecard_versions_tenant_chain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_health_scorecard_versions_tenant_chain ON public.health_scorecard_versions USING btree (workspace_id, health_scorecard_id, id);


--
-- Name: index_health_scorecards_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_health_scorecards_on_workspace_id ON public.health_scorecards USING btree (workspace_id);


--
-- Name: index_health_scorecards_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_health_scorecards_on_workspace_id_and_id ON public.health_scorecards USING btree (workspace_id, id);


--
-- Name: index_identity_candidates_on_account; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_identity_candidates_on_account ON public.identity_match_candidates USING btree (source_identity_id, account_id, key_kind) WHERE (account_id IS NOT NULL);


--
-- Name: index_identity_candidates_on_contact; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_identity_candidates_on_contact ON public.identity_match_candidates USING btree (source_identity_id, contact_id, key_kind) WHERE (contact_id IS NOT NULL);


--
-- Name: index_identity_match_candidates_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_identity_match_candidates_on_workspace_id ON public.identity_match_candidates USING btree (workspace_id);


--
-- Name: index_inbound_email_deliveries_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inbound_email_deliveries_on_source ON public.inbound_email_deliveries USING btree (shared_email_inbox_id, source_message_id, content_sha256);


--
-- Name: index_inbound_email_deliveries_on_visibility; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbound_email_deliveries_on_visibility ON public.inbound_email_deliveries USING btree (workspace_id, status, received_at);


--
-- Name: index_inbound_email_deliveries_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbound_email_deliveries_on_workspace_id ON public.inbound_email_deliveries USING btree (workspace_id);


--
-- Name: index_inbound_email_deliveries_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inbound_email_deliveries_on_workspace_id_and_id ON public.inbound_email_deliveries USING btree (workspace_id, id);


--
-- Name: index_installation_states_on_singleton; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_installation_states_on_singleton ON public.installation_states USING btree (singleton);


--
-- Name: index_integration_oauth_attempts_on_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_integration_oauth_attempts_on_session_id ON public.integration_oauth_attempts USING btree (session_id);


--
-- Name: index_integration_oauth_attempts_on_state_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_integration_oauth_attempts_on_state_digest ON public.integration_oauth_attempts USING btree (state_digest);


--
-- Name: index_integration_oauth_attempts_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_integration_oauth_attempts_on_workspace_id ON public.integration_oauth_attempts USING btree (workspace_id);


--
-- Name: index_integration_user_connections_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_integration_user_connections_on_workspace_id ON public.integration_user_connections USING btree (workspace_id);


--
-- Name: index_intercom_backfill_batches_boundary; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_backfill_batches_boundary ON public.intercom_backfill_batches USING btree (intercom_backfill_run_id, start_position, attempt_number);


--
-- Name: index_intercom_backfill_batches_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_backfill_batches_on_workspace_id ON public.intercom_backfill_batches USING btree (workspace_id);


--
-- Name: index_intercom_backfill_batches_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_backfill_batches_on_workspace_id_and_id ON public.intercom_backfill_batches USING btree (workspace_id, id);


--
-- Name: index_intercom_backfill_exceptions_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_backfill_exceptions_identity ON public.intercom_backfill_exceptions USING btree (intercom_backfill_manifest_id, remote_record_type, remote_record_id, exception_kind);


--
-- Name: index_intercom_backfill_exceptions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_backfill_exceptions_on_workspace_id ON public.intercom_backfill_exceptions USING btree (workspace_id);


--
-- Name: index_intercom_backfill_exceptions_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_backfill_exceptions_on_workspace_id_and_id ON public.intercom_backfill_exceptions USING btree (workspace_id, id);


--
-- Name: index_intercom_backfill_manifests_for_connection; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_backfill_manifests_for_connection ON public.intercom_backfill_manifests USING btree (intercom_connection_id, status, created_at);


--
-- Name: index_intercom_backfill_manifests_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_backfill_manifests_on_workspace_id ON public.intercom_backfill_manifests USING btree (workspace_id);


--
-- Name: index_intercom_backfill_manifests_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_backfill_manifests_on_workspace_id_and_id ON public.intercom_backfill_manifests USING btree (workspace_id, id);


--
-- Name: index_intercom_backfill_reports_on_intercom_backfill_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_backfill_reports_on_intercom_backfill_run_id ON public.intercom_backfill_reports USING btree (intercom_backfill_run_id);


--
-- Name: index_intercom_backfill_reports_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_backfill_reports_on_workspace_id ON public.intercom_backfill_reports USING btree (workspace_id);


--
-- Name: index_intercom_backfill_reports_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_backfill_reports_on_workspace_id_and_id ON public.intercom_backfill_reports USING btree (workspace_id, id);


--
-- Name: index_intercom_backfill_runs_for_connection; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_backfill_runs_for_connection ON public.intercom_backfill_runs USING btree (intercom_connection_id, status, created_at);


--
-- Name: index_intercom_backfill_runs_on_intercom_backfill_manifest_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_backfill_runs_on_intercom_backfill_manifest_id ON public.intercom_backfill_runs USING btree (intercom_backfill_manifest_id);


--
-- Name: index_intercom_backfill_runs_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_backfill_runs_on_workspace_id ON public.intercom_backfill_runs USING btree (workspace_id);


--
-- Name: index_intercom_backfill_runs_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_backfill_runs_on_workspace_id_and_id ON public.intercom_backfill_runs USING btree (workspace_id, id);


--
-- Name: index_intercom_connections_on_webhook_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_connections_on_webhook_key ON public.intercom_connections USING btree (webhook_key);


--
-- Name: index_intercom_connections_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_connections_on_workspace_id ON public.intercom_connections USING btree (workspace_id);


--
-- Name: index_intercom_connections_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_connections_on_workspace_id_and_id ON public.intercom_connections USING btree (workspace_id, id);


--
-- Name: index_intercom_conversation_links_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_conversation_links_on_workspace_id ON public.intercom_conversation_links USING btree (workspace_id);


--
-- Name: index_intercom_conversation_links_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_conversation_links_on_workspace_id_and_id ON public.intercom_conversation_links USING btree (workspace_id, id);


--
-- Name: index_intercom_conversations_on_remote_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_conversations_on_remote_id ON public.intercom_conversation_links USING btree (intercom_connection_id, remote_conversation_id);


--
-- Name: index_intercom_conversations_on_tenant_chain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_conversations_on_tenant_chain ON public.intercom_conversation_links USING btree (workspace_id, intercom_connection_id, id, conversation_id, support_case_id);


--
-- Name: index_intercom_conversations_on_tenant_conversation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_conversations_on_tenant_conversation ON public.intercom_conversation_links USING btree (workspace_id, intercom_connection_id, id, conversation_id);


--
-- Name: index_intercom_conversations_on_tenant_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_conversations_on_tenant_conversation_id ON public.intercom_conversation_links USING btree (workspace_id, id, conversation_id);


--
-- Name: index_intercom_conversations_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_conversations_on_tenant_id ON public.intercom_conversation_links USING btree (workspace_id, intercom_connection_id, id);


--
-- Name: index_intercom_drafts_on_source_artifact; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_drafts_on_source_artifact ON public.intercom_drafts USING btree (workspace_id, source_crew_artifact_id);


--
-- Name: index_intercom_drafts_on_tenant_link; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_drafts_on_tenant_link ON public.intercom_drafts USING btree (workspace_id, id, intercom_conversation_link_id, conversation_id);


--
-- Name: index_intercom_drafts_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_drafts_on_workspace_id ON public.intercom_drafts USING btree (workspace_id);


--
-- Name: index_intercom_drafts_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_drafts_on_workspace_id_and_id ON public.intercom_drafts USING btree (workspace_id, id);


--
-- Name: index_intercom_drafts_on_workspace_id_and_support_case_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_drafts_on_workspace_id_and_support_case_id ON public.intercom_drafts USING btree (workspace_id, support_case_id);


--
-- Name: index_intercom_outbound_deliveries_on_source_artifact; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_outbound_deliveries_on_source_artifact ON public.intercom_outbound_deliveries USING btree (workspace_id, source_crew_artifact_id);


--
-- Name: index_intercom_outbound_deliveries_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_outbound_deliveries_on_workspace_id ON public.intercom_outbound_deliveries USING btree (workspace_id);


--
-- Name: index_intercom_outbound_deliveries_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_outbound_deliveries_on_workspace_id_and_id ON public.intercom_outbound_deliveries USING btree (workspace_id, id);


--
-- Name: index_intercom_outbound_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_outbound_on_idempotency ON public.intercom_outbound_deliveries USING btree (workspace_id, idempotency_key);


--
-- Name: index_intercom_outbound_on_remote_part; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_outbound_on_remote_part ON public.intercom_outbound_deliveries USING btree (intercom_connection_id, remote_part_id) WHERE (remote_part_id IS NOT NULL);


--
-- Name: index_intercom_part_attachments_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_part_attachments_on_workspace_id ON public.intercom_part_attachments USING btree (workspace_id);


--
-- Name: index_intercom_part_attachments_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_part_attachments_on_workspace_id_and_id ON public.intercom_part_attachments USING btree (workspace_id, id);


--
-- Name: index_intercom_part_attachments_remote; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_part_attachments_remote ON public.intercom_part_attachments USING btree (intercom_part_link_id, remote_attachment_id);


--
-- Name: index_intercom_part_links_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_part_links_on_workspace_id ON public.intercom_part_links USING btree (workspace_id);


--
-- Name: index_intercom_part_links_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_part_links_on_workspace_id_and_id ON public.intercom_part_links USING btree (workspace_id, id);


--
-- Name: index_intercom_parts_on_conversation_message; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_parts_on_conversation_message ON public.intercom_part_links USING btree (workspace_id, conversation_id, conversation_message_id) WHERE (conversation_message_id IS NOT NULL);


--
-- Name: index_intercom_sync_operations_on_operation_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_sync_operations_on_operation_key ON public.intercom_sync_operations USING btree (operation_key);


--
-- Name: index_intercom_sync_operations_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_sync_operations_on_workspace_id ON public.intercom_sync_operations USING btree (workspace_id);


--
-- Name: index_intercom_sync_operations_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_sync_operations_on_workspace_id_and_id ON public.intercom_sync_operations USING btree (workspace_id, id);


--
-- Name: index_intercom_tag_links_on_intercom_connection_id_and_tag_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_tag_links_on_intercom_connection_id_and_tag_id ON public.intercom_tag_links USING btree (intercom_connection_id, tag_id);


--
-- Name: index_intercom_tag_links_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_tag_links_on_workspace_id ON public.intercom_tag_links USING btree (workspace_id);


--
-- Name: index_intercom_tag_links_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_tag_links_on_workspace_id_and_id ON public.intercom_tag_links USING btree (workspace_id, id);


--
-- Name: index_intercom_webhook_deliveries_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_webhook_deliveries_on_workspace_id ON public.intercom_webhook_deliveries USING btree (workspace_id);


--
-- Name: index_intercom_webhook_deliveries_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_webhook_deliveries_on_workspace_id_and_id ON public.intercom_webhook_deliveries USING btree (workspace_id, id);


--
-- Name: index_intercom_webhooks_on_notification; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercom_webhooks_on_notification ON public.intercom_webhook_deliveries USING btree (intercom_connection_id, notification_id);


--
-- Name: index_intercom_webhooks_on_visibility; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercom_webhooks_on_visibility ON public.intercom_webhook_deliveries USING btree (workspace_id, status, received_at);


--
-- Name: index_knowledge_applicabilities_on_intercom_connection_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_applicabilities_on_intercom_connection_id ON public.knowledge_applicabilities USING btree (intercom_connection_id);


--
-- Name: index_knowledge_applicabilities_on_knowledge_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_applicabilities_on_knowledge_source_id ON public.knowledge_applicabilities USING btree (knowledge_source_id);


--
-- Name: index_knowledge_applicabilities_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_applicabilities_on_workspace_id ON public.knowledge_applicabilities USING btree (workspace_id);


--
-- Name: index_knowledge_applicabilities_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_applicabilities_on_workspace_id_and_id ON public.knowledge_applicabilities USING btree (workspace_id, id);


--
-- Name: index_knowledge_applicability_connections_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_applicability_connections_on_workspace_id ON public.knowledge_applicability_connections USING btree (workspace_id);


--
-- Name: index_knowledge_applicability_connections_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_applicability_connections_unique ON public.knowledge_applicability_connections USING btree (knowledge_applicability_id, intercom_connection_id);


--
-- Name: index_knowledge_applicability_products_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_applicability_products_on_workspace_id ON public.knowledge_applicability_products USING btree (workspace_id);


--
-- Name: index_knowledge_applicability_products_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_applicability_products_unique ON public.knowledge_applicability_products USING btree (knowledge_applicability_id, product_id);


--
-- Name: index_knowledge_source_versions_on_search_document; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_source_versions_on_search_document ON public.knowledge_source_versions USING gin (search_document);


--
-- Name: index_knowledge_source_versions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_source_versions_on_workspace_id ON public.knowledge_source_versions USING btree (workspace_id);


--
-- Name: index_knowledge_source_versions_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_source_versions_on_workspace_id_and_id ON public.knowledge_source_versions USING btree (workspace_id, id);


--
-- Name: index_knowledge_sources_on_connection_article; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sources_on_connection_article ON public.knowledge_sources USING btree (workspace_id, intercom_connection_id, external_id) WHERE (intercom_connection_id IS NOT NULL);


--
-- Name: index_knowledge_sources_on_notion_page; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sources_on_notion_page ON public.knowledge_sources USING btree (notion_knowledge_connection_id, external_id) WHERE (notion_knowledge_connection_id IS NOT NULL);


--
-- Name: index_knowledge_sources_on_source_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sources_on_source_key ON public.knowledge_sources USING btree (source_key);


--
-- Name: index_knowledge_sources_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_sources_on_workspace_id ON public.knowledge_sources USING btree (workspace_id);


--
-- Name: index_knowledge_sources_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sources_on_workspace_id_and_id ON public.knowledge_sources USING btree (workspace_id, id);


--
-- Name: index_knowledge_sources_on_workspace_kind_external; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sources_on_workspace_kind_external ON public.knowledge_sources USING btree (workspace_id, source_kind, external_id) WHERE ((external_id IS NOT NULL) AND (intercom_connection_id IS NULL) AND (notion_knowledge_connection_id IS NULL));


--
-- Name: index_knowledge_sources_on_workspace_kind_url; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sources_on_workspace_kind_url ON public.knowledge_sources USING btree (workspace_id, source_kind, canonical_url) WHERE (canonical_url IS NOT NULL);


--
-- Name: index_knowledge_sync_observations_on_knowledge_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sync_observations_on_knowledge_source_id ON public.knowledge_sync_observations USING btree (knowledge_source_id);


--
-- Name: index_knowledge_sync_observations_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_sync_observations_on_workspace_id ON public.knowledge_sync_observations USING btree (workspace_id);


--
-- Name: index_knowledge_sync_observations_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sync_observations_on_workspace_id_and_id ON public.knowledge_sync_observations USING btree (workspace_id, id);


--
-- Name: index_knowledge_sync_passes_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sync_passes_active ON public.knowledge_sync_passes USING btree (intercom_connection_id) WHERE (completed_at IS NULL);


--
-- Name: index_knowledge_sync_passes_notion_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sync_passes_notion_active ON public.knowledge_sync_passes USING btree (notion_knowledge_connection_id) WHERE (completed_at IS NULL);


--
-- Name: index_knowledge_sync_passes_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_sync_passes_on_workspace_id ON public.knowledge_sync_passes USING btree (workspace_id);


--
-- Name: index_knowledge_sync_passes_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sync_passes_on_workspace_id_and_id ON public.knowledge_sync_passes USING btree (workspace_id, id);


--
-- Name: index_knowledge_versions_on_source_and_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_versions_on_source_and_number ON public.knowledge_source_versions USING btree (knowledge_source_id, version_number);


--
-- Name: index_knowledge_versions_on_workspace_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_versions_on_workspace_source_id ON public.knowledge_source_versions USING btree (workspace_id, knowledge_source_id, id);


--
-- Name: index_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memberships_on_user_id ON public.memberships USING btree (user_id);


--
-- Name: index_memberships_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memberships_on_workspace_id ON public.memberships USING btree (workspace_id);


--
-- Name: index_memberships_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memberships_on_workspace_id_and_id ON public.memberships USING btree (workspace_id, id);


--
-- Name: index_memberships_on_workspace_id_and_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memberships_on_workspace_id_and_role ON public.memberships USING btree (workspace_id, role);


--
-- Name: index_memberships_on_workspace_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memberships_on_workspace_id_and_user_id ON public.memberships USING btree (workspace_id, user_id);


--
-- Name: index_memberships_on_workspace_id_id_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memberships_on_workspace_id_id_user_id ON public.memberships USING btree (workspace_id, id, user_id);


--
-- Name: index_memory_correction_proposals_on_memory_record_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_correction_proposals_on_memory_record_id ON public.memory_correction_proposals USING btree (memory_record_id);


--
-- Name: index_memory_correction_proposals_on_proposal_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_correction_proposals_on_proposal_key ON public.memory_correction_proposals USING btree (proposal_key);


--
-- Name: index_memory_correction_proposals_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_correction_proposals_on_workspace_id ON public.memory_correction_proposals USING btree (workspace_id);


--
-- Name: index_memory_correction_proposals_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_correction_proposals_on_workspace_id_and_id ON public.memory_correction_proposals USING btree (workspace_id, id);


--
-- Name: index_memory_correction_proposals_on_workspace_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_correction_proposals_on_workspace_id_and_status ON public.memory_correction_proposals USING btree (workspace_id, status);


--
-- Name: index_memory_index_entries_on_memory_record_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_index_entries_on_memory_record_id ON public.memory_index_entries USING btree (memory_record_id);


--
-- Name: index_memory_index_entries_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_index_entries_on_workspace_id ON public.memory_index_entries USING btree (workspace_id);


--
-- Name: index_memory_index_entries_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_index_entries_on_workspace_id_and_id ON public.memory_index_entries USING btree (workspace_id, id);


--
-- Name: index_memory_index_entries_on_workspace_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_index_entries_on_workspace_id_and_status ON public.memory_index_entries USING btree (workspace_id, status);


--
-- Name: index_memory_proposals_on_proposal_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_proposals_on_proposal_key ON public.memory_proposals USING btree (proposal_key);


--
-- Name: index_memory_proposals_on_source_agent_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_proposals_on_source_agent_profile_id ON public.memory_proposals USING btree (source_agent_profile_id);


--
-- Name: index_memory_proposals_on_source_and_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_proposals_on_source_and_digest ON public.memory_proposals USING btree (workspace_id, source_crew_artifact_id, content_digest);


--
-- Name: index_memory_proposals_on_source_crew_artifact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_proposals_on_source_crew_artifact_id ON public.memory_proposals USING btree (source_crew_artifact_id);


--
-- Name: index_memory_proposals_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_proposals_on_workspace_id ON public.memory_proposals USING btree (workspace_id);


--
-- Name: index_memory_proposals_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_proposals_on_workspace_id_and_id ON public.memory_proposals USING btree (workspace_id, id);


--
-- Name: index_memory_proposals_on_workspace_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_proposals_on_workspace_id_and_status ON public.memory_proposals USING btree (workspace_id, status);


--
-- Name: index_memory_records_on_memory_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_records_on_memory_key ON public.memory_records USING btree (memory_key);


--
-- Name: index_memory_records_on_source_human; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_source_human ON public.memory_records USING btree (workspace_id, source_membership_id, source_user_id) WHERE (source_membership_id IS NOT NULL);


--
-- Name: index_memory_records_on_supersedes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_supersedes ON public.memory_records USING btree (workspace_id, supersedes_memory_record_id) WHERE (supersedes_memory_record_id IS NOT NULL);


--
-- Name: index_memory_records_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_id ON public.memory_records USING btree (workspace_id);


--
-- Name: index_memory_records_on_workspace_id_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_id_and_account_id ON public.memory_records USING btree (workspace_id, account_id) WHERE (account_id IS NOT NULL);


--
-- Name: index_memory_records_on_workspace_id_and_agent_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_id_and_agent_profile_id ON public.memory_records USING btree (workspace_id, agent_profile_id) WHERE (agent_profile_id IS NOT NULL);


--
-- Name: index_memory_records_on_workspace_id_and_capture_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_records_on_workspace_id_and_capture_key ON public.memory_records USING btree (workspace_id, capture_key) WHERE (capture_key IS NOT NULL);


--
-- Name: index_memory_records_on_workspace_id_and_contact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_id_and_contact_id ON public.memory_records USING btree (workspace_id, contact_id) WHERE (contact_id IS NOT NULL);


--
-- Name: index_memory_records_on_workspace_id_and_crew_template_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_id_and_crew_template_id ON public.memory_records USING btree (workspace_id, crew_template_id) WHERE (crew_template_id IS NOT NULL);


--
-- Name: index_memory_records_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_records_on_workspace_id_and_id ON public.memory_records USING btree (workspace_id, id);


--
-- Name: index_memory_records_on_workspace_id_and_observed_at_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_id_and_observed_at_and_id ON public.memory_records USING btree (workspace_id, observed_at DESC, id DESC);


--
-- Name: index_memory_records_on_workspace_id_and_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_id_and_organization_id ON public.memory_records USING btree (workspace_id, organization_id) WHERE (organization_id IS NOT NULL);


--
-- Name: index_memory_records_on_workspace_id_and_scope_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_id_and_scope_kind ON public.memory_records USING btree (workspace_id, scope_kind);


--
-- Name: index_memory_records_on_workspace_id_and_support_case_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_id_and_support_case_id ON public.memory_records USING btree (workspace_id, support_case_id) WHERE (support_case_id IS NOT NULL);


--
-- Name: index_memory_records_on_workspace_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_id_and_user_id ON public.memory_records USING btree (workspace_id, user_id) WHERE (user_id IS NOT NULL);


--
-- Name: index_memory_records_on_workspace_type_topic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_records_on_workspace_type_topic ON public.memory_records USING btree (workspace_id, memory_type, topic);


--
-- Name: index_memory_tombstones_on_memory_record_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_tombstones_on_memory_record_id ON public.memory_tombstones USING btree (memory_record_id);


--
-- Name: index_memory_tombstones_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_tombstones_on_workspace_id ON public.memory_tombstones USING btree (workspace_id);


--
-- Name: index_memory_tombstones_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_tombstones_on_workspace_id_and_id ON public.memory_tombstones USING btree (workspace_id, id);


--
-- Name: index_memory_tombstones_on_workspace_id_and_index_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_tombstones_on_workspace_id_and_index_status ON public.memory_tombstones USING btree (workspace_id, index_status);


--
-- Name: index_memory_tombstones_on_workspace_id_and_memory_record_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_tombstones_on_workspace_id_and_memory_record_id ON public.memory_tombstones USING btree (workspace_id, memory_record_id);


--
-- Name: index_message_attachments_on_message_and_attachment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_message_attachments_on_message_and_attachment ON public.conversation_message_attachments USING btree (conversation_message_id, stored_attachment_id);


--
-- Name: index_notifications_inbox; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_inbox ON public.notifications USING btree (recipient_membership_id, read_at, occurred_at);


--
-- Name: index_notifications_on_recipient_and_event; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_notifications_on_recipient_and_event ON public.notifications USING btree (recipient_membership_id, source_audit_event_id);


--
-- Name: index_notifications_on_recipient_membership_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_recipient_membership_id ON public.notifications USING btree (recipient_membership_id);


--
-- Name: index_notifications_on_source_audit_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_source_audit_event_id ON public.notifications USING btree (source_audit_event_id);


--
-- Name: index_notifications_on_workspace_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_notifications_on_workspace_and_id ON public.notifications USING btree (workspace_id, id);


--
-- Name: index_notifications_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_workspace_id ON public.notifications USING btree (workspace_id);


--
-- Name: index_notion_knowledge_connections_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notion_knowledge_connections_on_workspace_id ON public.notion_knowledge_connections USING btree (workspace_id);


--
-- Name: index_notion_knowledge_connections_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_notion_knowledge_connections_on_workspace_id_and_id ON public.notion_knowledge_connections USING btree (workspace_id, id);


--
-- Name: index_oidc_identities_on_issuer_and_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_oidc_identities_on_issuer_and_subject ON public.oidc_identities USING btree (issuer, subject);


--
-- Name: index_oidc_identities_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_oidc_identities_on_user_id ON public.oidc_identities USING btree (user_id);


--
-- Name: index_operational_checks_for_cockpit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_operational_checks_for_cockpit ON public.operational_checks USING btree (workspace_id, check_kind, checked_at, id);


--
-- Name: index_operational_checks_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_operational_checks_on_workspace_id ON public.operational_checks USING btree (workspace_id);


--
-- Name: index_operational_checks_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_operational_checks_on_workspace_id_and_id ON public.operational_checks USING btree (workspace_id, id);


--
-- Name: index_organizations_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_organizations_on_slug ON public.organizations USING btree (slug);


--
-- Name: index_outbound_email_deliveries_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbound_email_deliveries_on_idempotency ON public.outbound_email_deliveries USING btree (workspace_id, idempotency_key);


--
-- Name: index_outbound_email_deliveries_on_source_artifact; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbound_email_deliveries_on_source_artifact ON public.outbound_email_deliveries USING btree (workspace_id, source_crew_artifact_id);


--
-- Name: index_outbound_email_deliveries_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbound_email_deliveries_on_workspace_id ON public.outbound_email_deliveries USING btree (workspace_id);


--
-- Name: index_outbound_email_deliveries_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbound_email_deliveries_on_workspace_id_and_id ON public.outbound_email_deliveries USING btree (workspace_id, id);


--
-- Name: index_outbound_email_delivery_attachments_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbound_email_delivery_attachments_on_workspace_id ON public.outbound_email_delivery_attachments USING btree (workspace_id);


--
-- Name: index_outbound_webhook_deliveries_on_event_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbound_webhook_deliveries_on_event_key ON public.outbound_webhook_deliveries USING btree (event_key);


--
-- Name: index_outbound_webhook_deliveries_on_notification_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbound_webhook_deliveries_on_notification_id ON public.outbound_webhook_deliveries USING btree (notification_id);


--
-- Name: index_outbound_webhook_deliveries_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbound_webhook_deliveries_on_workspace_id ON public.outbound_webhook_deliveries USING btree (workspace_id);


--
-- Name: index_outbound_webhook_endpoints_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbound_webhook_endpoints_on_workspace_id ON public.outbound_webhook_endpoints USING btree (workspace_id);


--
-- Name: index_outbound_webhook_endpoints_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbound_webhook_endpoints_on_workspace_id_and_id ON public.outbound_webhook_endpoints USING btree (workspace_id, id);


--
-- Name: index_outbound_webhook_endpoints_on_workspace_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbound_webhook_endpoints_on_workspace_id_and_name ON public.outbound_webhook_endpoints USING btree (workspace_id, name);


--
-- Name: index_outbound_webhooks_on_endpoint_and_notification; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbound_webhooks_on_endpoint_and_notification ON public.outbound_webhook_deliveries USING btree (outbound_webhook_endpoint_id, notification_id);


--
-- Name: index_pending_workspace_invitations_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_pending_workspace_invitations_on_email ON public.workspace_invitations USING btree (workspace_id, lower((email_address)::text)) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_personal_provider_accounts_on_account_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_personal_provider_accounts_on_account_key ON public.personal_provider_accounts USING btree (account_key);


--
-- Name: index_personal_provider_accounts_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_personal_provider_accounts_on_workspace_id ON public.personal_provider_accounts USING btree (workspace_id);


--
-- Name: index_personal_provider_accounts_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_personal_provider_accounts_on_workspace_id_and_id ON public.personal_provider_accounts USING btree (workspace_id, id);


--
-- Name: index_policy_previews_proposal_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_policy_previews_proposal_identity ON public.governed_policy_previews USING btree (workspace_id, governed_policy_proposal_id, id);


--
-- Name: index_policy_proposals_candidate_contract; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_policy_proposals_candidate_contract ON public.governed_policy_proposals USING btree (resolution_contract_version_id);


--
-- Name: index_policy_proposals_candidate_profile; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_policy_proposals_candidate_profile ON public.governed_policy_proposals USING btree (agent_profile_version_id);


--
-- Name: index_policy_publications_contract_tuple; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_policy_publications_contract_tuple ON public.governed_policy_publications USING btree (workspace_id, id, resolution_contract_version_id);


--
-- Name: index_policy_publications_frozen_tuple; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_policy_publications_frozen_tuple ON public.governed_policy_publications USING btree (workspace_id, id, resolution_contract_version_id, agent_profile_version_id);


--
-- Name: index_policy_publications_one_canary_per_preview; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_policy_publications_one_canary_per_preview ON public.governed_policy_publications USING btree (governed_policy_preview_id) WHERE ((action)::text = 'canary'::text);


--
-- Name: index_policy_publications_one_successor; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_policy_publications_one_successor ON public.governed_policy_publications USING btree (supersedes_publication_id) WHERE (supersedes_publication_id IS NOT NULL);


--
-- Name: index_policy_subjects_unique_account; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_policy_subjects_unique_account ON public.governed_policy_subjects USING btree (governed_policy_proposal_id, account_id) WHERE ((subject_kind)::text = 'account'::text);


--
-- Name: index_policy_subjects_unique_case; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_policy_subjects_unique_case ON public.governed_policy_subjects USING btree (governed_policy_proposal_id, support_case_id) WHERE ((subject_kind)::text = 'support_case'::text);


--
-- Name: index_policy_subjects_unique_profile; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_policy_subjects_unique_profile ON public.governed_policy_subjects USING btree (governed_policy_proposal_id, agent_profile_id) WHERE ((subject_kind)::text = 'agent_profile'::text);


--
-- Name: index_products_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_products_on_workspace_id ON public.products USING btree (workspace_id);


--
-- Name: index_products_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_products_on_workspace_id_and_id ON public.products USING btree (workspace_id, id);


--
-- Name: index_products_on_workspace_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_products_on_workspace_name ON public.products USING btree (workspace_id, lower((name)::text));


--
-- Name: index_public_web_extractions_on_public_web_search_result_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_public_web_extractions_on_public_web_search_result_id ON public.public_web_extractions USING btree (public_web_search_result_id);


--
-- Name: index_public_web_extractions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_public_web_extractions_on_workspace_id ON public.public_web_extractions USING btree (workspace_id);


--
-- Name: index_public_web_extractions_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_public_web_extractions_on_workspace_id_and_id ON public.public_web_extractions USING btree (workspace_id, id);


--
-- Name: index_public_web_extractions_on_workspace_id_and_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_public_web_extractions_on_workspace_id_and_request_key ON public.public_web_extractions USING btree (workspace_id, request_key);


--
-- Name: index_public_web_search_results_on_citation_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_public_web_search_results_on_citation_key ON public.public_web_search_results USING btree (citation_key);


--
-- Name: index_public_web_search_results_on_public_web_search_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_public_web_search_results_on_public_web_search_id ON public.public_web_search_results USING btree (public_web_search_id);


--
-- Name: index_public_web_search_results_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_public_web_search_results_on_workspace_id ON public.public_web_search_results USING btree (workspace_id);


--
-- Name: index_public_web_search_results_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_public_web_search_results_on_workspace_id_and_id ON public.public_web_search_results USING btree (workspace_id, id);


--
-- Name: index_public_web_searches_on_crew_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_public_web_searches_on_crew_task_id ON public.public_web_searches USING btree (crew_task_id);


--
-- Name: index_public_web_searches_on_usage_rate_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_public_web_searches_on_usage_rate_version_id ON public.public_web_searches USING btree (usage_rate_version_id);


--
-- Name: index_public_web_searches_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_public_web_searches_on_workspace_id ON public.public_web_searches USING btree (workspace_id);


--
-- Name: index_public_web_searches_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_public_web_searches_on_workspace_id_and_id ON public.public_web_searches USING btree (workspace_id, id);


--
-- Name: index_public_web_searches_on_workspace_id_and_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_public_web_searches_on_workspace_id_and_request_key ON public.public_web_searches USING btree (workspace_id, request_key);


--
-- Name: index_resolution_contract_families_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resolution_contract_families_on_workspace_id_and_id ON public.resolution_contract_families USING btree (workspace_id, id);


--
-- Name: index_resolution_contract_families_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resolution_contract_families_unique ON public.resolution_contract_families USING btree (workspace_id, family_key);


--
-- Name: index_resolution_contract_versions_on_family_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resolution_contract_versions_on_family_version ON public.resolution_contract_versions USING btree (resolution_contract_family_id, version_number);


--
-- Name: index_resolution_contract_versions_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resolution_contract_versions_on_workspace_id_and_id ON public.resolution_contract_versions USING btree (workspace_id, id);


--
-- Name: index_resolution_contract_versions_tenant_chain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resolution_contract_versions_tenant_chain ON public.resolution_contract_versions USING btree (workspace_id, resolution_contract_family_id, id);


--
-- Name: index_runtime_installations_on_personal_provider_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_runtime_installations_on_personal_provider_account_id ON public.runtime_installations USING btree (personal_provider_account_id);


--
-- Name: index_runtime_installations_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_runtime_installations_on_workspace_id ON public.runtime_installations USING btree (workspace_id);


--
-- Name: index_runtime_installations_on_workspace_id_and_detection_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_runtime_installations_on_workspace_id_and_detection_key ON public.runtime_installations USING btree (workspace_id, detection_key);


--
-- Name: index_runtime_installations_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_runtime_installations_on_workspace_id_and_id ON public.runtime_installations USING btree (workspace_id, id);


--
-- Name: index_service_calendar_holidays_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_calendar_holidays_on_workspace_id ON public.service_calendar_holidays USING btree (workspace_id);


--
-- Name: index_service_calendar_holidays_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_service_calendar_holidays_on_workspace_id_and_id ON public.service_calendar_holidays USING btree (workspace_id, id);


--
-- Name: index_service_calendars_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_calendars_on_workspace_id ON public.service_calendars USING btree (workspace_id);


--
-- Name: index_service_calendars_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_service_calendars_on_workspace_id_and_id ON public.service_calendars USING btree (workspace_id, id);


--
-- Name: index_service_calendars_on_workspace_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_service_calendars_on_workspace_id_and_name ON public.service_calendars USING btree (workspace_id, name);


--
-- Name: index_sessions_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_expires_at ON public.sessions USING btree (expires_at);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_shared_email_inboxes_on_webhook_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_shared_email_inboxes_on_webhook_key ON public.shared_email_inboxes USING btree (webhook_key);


--
-- Name: index_shared_email_inboxes_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_shared_email_inboxes_on_workspace_id ON public.shared_email_inboxes USING btree (workspace_id);


--
-- Name: index_shared_email_inboxes_on_workspace_id_and_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_shared_email_inboxes_on_workspace_id_and_email_address ON public.shared_email_inboxes USING btree (workspace_id, email_address);


--
-- Name: index_shared_email_inboxes_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_shared_email_inboxes_on_workspace_id_and_id ON public.shared_email_inboxes USING btree (workspace_id, id);


--
-- Name: index_sla_escalation_tasks_on_event; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sla_escalation_tasks_on_event ON public.sla_escalation_tasks USING btree (case_sla_id, objective, kind);


--
-- Name: index_sla_escalation_tasks_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sla_escalation_tasks_on_workspace_id ON public.sla_escalation_tasks USING btree (workspace_id);


--
-- Name: index_sla_escalation_tasks_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sla_escalation_tasks_on_workspace_id_and_id ON public.sla_escalation_tasks USING btree (workspace_id, id);


--
-- Name: index_sla_policies_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sla_policies_on_workspace_id ON public.sla_policies USING btree (workspace_id);


--
-- Name: index_sla_policies_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sla_policies_on_workspace_id_and_id ON public.sla_policies USING btree (workspace_id, id);


--
-- Name: index_source_identities_on_resolved_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_source_identities_on_resolved_by_id ON public.source_identities USING btree (resolved_by_id);


--
-- Name: index_source_identities_on_source_record; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_source_identities_on_source_record ON public.source_identities USING btree (workspace_id, source_namespace, source_record_type, source_record_id);


--
-- Name: index_source_identities_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_source_identities_on_workspace_id ON public.source_identities USING btree (workspace_id);


--
-- Name: index_source_identities_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_source_identities_on_workspace_id_and_id ON public.source_identities USING btree (workspace_id, id);


--
-- Name: index_source_identity_keys_for_matching; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_source_identity_keys_for_matching ON public.source_identity_keys USING btree (workspace_id, kind, normalized_value) WHERE (retired_at IS NULL);


--
-- Name: index_source_identity_keys_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_source_identity_keys_on_workspace_id ON public.source_identity_keys USING btree (workspace_id);


--
-- Name: index_stored_attachments_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stored_attachments_on_workspace_id ON public.stored_attachments USING btree (workspace_id);


--
-- Name: index_stored_attachments_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stored_attachments_on_workspace_id_and_id ON public.stored_attachments USING btree (workspace_id, id);


--
-- Name: index_support_case_products_on_support_case_id_and_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_support_case_products_on_support_case_id_and_product_id ON public.support_case_products USING btree (support_case_id, product_id);


--
-- Name: index_support_case_products_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_support_case_products_on_workspace_id ON public.support_case_products USING btree (workspace_id);


--
-- Name: index_support_case_status_changes_on_timeline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_support_case_status_changes_on_timeline ON public.support_case_status_changes USING btree (support_case_id, occurred_at, id);


--
-- Name: index_support_case_status_changes_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_support_case_status_changes_on_workspace_id ON public.support_case_status_changes USING btree (workspace_id);


--
-- Name: index_support_case_taggings_on_support_case_id_and_tag_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_support_case_taggings_on_support_case_id_and_tag_id ON public.support_case_taggings USING btree (support_case_id, tag_id);


--
-- Name: index_support_case_taggings_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_support_case_taggings_on_workspace_id ON public.support_case_taggings USING btree (workspace_id);


--
-- Name: index_support_cases_on_assignment_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_support_cases_on_assignment_queue ON public.support_cases USING btree (workspace_id, assigned_membership_id, status);


--
-- Name: index_support_cases_on_tenant_conversation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_support_cases_on_tenant_conversation ON public.support_cases USING btree (workspace_id, id, conversation_id);


--
-- Name: index_support_cases_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_support_cases_on_workspace_id ON public.support_cases USING btree (workspace_id);


--
-- Name: index_support_cases_on_workspace_id_and_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_support_cases_on_workspace_id_and_conversation_id ON public.support_cases USING btree (workspace_id, conversation_id);


--
-- Name: index_support_cases_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_support_cases_on_workspace_id_and_id ON public.support_cases USING btree (workspace_id, id);


--
-- Name: index_support_cases_on_workspace_id_and_status_and_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_support_cases_on_workspace_id_and_status_and_priority ON public.support_cases USING btree (workspace_id, status, priority);


--
-- Name: index_tags_on_workspace_and_lower_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tags_on_workspace_and_lower_name ON public.tags USING btree (workspace_id, lower((name)::text));


--
-- Name: index_tags_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tags_on_workspace_id ON public.tags USING btree (workspace_id);


--
-- Name: index_tags_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tags_on_workspace_id_and_id ON public.tags USING btree (workspace_id, id);


--
-- Name: index_usage_cost_snapshots_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_usage_cost_snapshots_on_workspace_id_and_id ON public.usage_cost_snapshots USING btree (workspace_id, id);


--
-- Name: index_usage_cost_snapshots_unique_run; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_usage_cost_snapshots_unique_run ON public.usage_cost_snapshots USING btree (execution_run_id) WHERE (execution_run_id IS NOT NULL);


--
-- Name: index_usage_cost_snapshots_unique_search; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_usage_cost_snapshots_unique_search ON public.usage_cost_snapshots USING btree (public_web_search_id) WHERE (public_web_search_id IS NOT NULL);


--
-- Name: index_usage_rate_settings_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_usage_rate_settings_on_workspace_id ON public.usage_rate_settings USING btree (workspace_id);


--
-- Name: index_usage_rate_settings_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_usage_rate_settings_on_workspace_id_and_id ON public.usage_rate_settings USING btree (workspace_id, id);


--
-- Name: index_usage_rate_versions_on_setting_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_usage_rate_versions_on_setting_version ON public.usage_rate_versions USING btree (usage_rate_setting_id, version_number);


--
-- Name: index_usage_rate_versions_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_usage_rate_versions_on_workspace_id_and_id ON public.usage_rate_versions USING btree (workspace_id, id);


--
-- Name: index_usage_rate_versions_tenant_chain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_usage_rate_versions_tenant_chain ON public.usage_rate_versions USING btree (workspace_id, usage_rate_setting_id, id);


--
-- Name: index_users_on_lower_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_lower_email_address ON public.users USING btree (lower((email_address)::text));


--
-- Name: index_users_on_unique_break_glass; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_unique_break_glass ON public.users USING btree (break_glass) WHERE break_glass;


--
-- Name: index_workspace_connectors_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_connectors_on_workspace_id ON public.workspace_connectors USING btree (workspace_id);


--
-- Name: index_workspace_connectors_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workspace_connectors_on_workspace_id_and_id ON public.workspace_connectors USING btree (workspace_id, id);


--
-- Name: index_workspace_connectors_on_workspace_id_and_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workspace_connectors_on_workspace_id_and_provider ON public.workspace_connectors USING btree (workspace_id, provider);


--
-- Name: index_workspace_content_expiry_runs_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_content_expiry_runs_on_workspace_id ON public.workspace_content_expiry_runs USING btree (workspace_id);


--
-- Name: index_workspace_data_policies_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workspace_data_policies_on_workspace_id ON public.workspace_data_policies USING btree (workspace_id);


--
-- Name: index_workspace_deletion_requests_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_deletion_requests_on_requested_by_id ON public.workspace_deletion_requests USING btree (requested_by_id);


--
-- Name: index_workspace_deletion_requests_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workspace_deletion_requests_on_workspace_id ON public.workspace_deletion_requests USING btree (workspace_id);


--
-- Name: index_workspace_invitations_on_accepted_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_invitations_on_accepted_by_id ON public.workspace_invitations USING btree (accepted_by_id);


--
-- Name: index_workspace_invitations_on_invited_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_invitations_on_invited_by_id ON public.workspace_invitations USING btree (invited_by_id);


--
-- Name: index_workspace_invitations_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_invitations_on_workspace_id ON public.workspace_invitations USING btree (workspace_id);


--
-- Name: index_workspace_tombstones_on_deleted_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_tombstones_on_deleted_by_id ON public.workspace_tombstones USING btree (deleted_by_id);


--
-- Name: index_workspace_tombstones_on_former_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workspace_tombstones_on_former_workspace_id ON public.workspace_tombstones USING btree (former_workspace_id);


--
-- Name: index_workspace_tombstones_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_tombstones_on_organization_id ON public.workspace_tombstones USING btree (organization_id);


--
-- Name: index_workspaces_on_deletion_requested_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspaces_on_deletion_requested_at ON public.workspaces USING btree (deletion_requested_at);


--
-- Name: index_workspaces_on_id_and_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workspaces_on_id_and_organization_id ON public.workspaces USING btree (id, organization_id);


--
-- Name: index_workspaces_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspaces_on_organization_id ON public.workspaces USING btree (organization_id);


--
-- Name: index_workspaces_on_organization_id_and_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workspaces_on_organization_id_and_slug ON public.workspaces USING btree (organization_id, slug);


--
-- Name: index_workspaces_on_runner_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workspaces_on_runner_key ON public.workspaces USING btree (runner_key);


--
-- Name: personal_accounts_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX personal_accounts_identity ON public.personal_provider_accounts USING btree (workspace_id, account_key, membership_id);


--
-- Name: account_health_assessments account_health_assessments_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER account_health_assessments_append_only BEFORE DELETE OR UPDATE ON public.account_health_assessments FOR EACH ROW EXECUTE FUNCTION public.protect_account_health_snapshot();


--
-- Name: account_health_assessments account_health_assessments_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER account_health_assessments_no_truncate BEFORE TRUNCATE ON public.account_health_assessments FOR EACH STATEMENT EXECUTE FUNCTION public.protect_account_health_snapshot();


--
-- Name: account_health_inputs account_health_inputs_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER account_health_inputs_append_only BEFORE DELETE OR UPDATE ON public.account_health_inputs FOR EACH ROW EXECUTE FUNCTION public.protect_account_health_snapshot();


--
-- Name: account_health_inputs account_health_inputs_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER account_health_inputs_no_truncate BEFORE TRUNCATE ON public.account_health_inputs FOR EACH STATEMENT EXECUTE FUNCTION public.protect_account_health_snapshot();


--
-- Name: account_health_signals account_health_signals_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER account_health_signals_append_only BEFORE DELETE OR UPDATE ON public.account_health_signals FOR EACH ROW EXECUTE FUNCTION public.protect_account_health_snapshot();


--
-- Name: account_health_signals account_health_signals_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER account_health_signals_no_truncate BEFORE TRUNCATE ON public.account_health_signals FOR EACH STATEMENT EXECUTE FUNCTION public.protect_account_health_snapshot();


--
-- Name: active_storage_attachments active_storage_attachments_no_stored_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER active_storage_attachments_no_stored_truncate BEFORE TRUNCATE ON public.active_storage_attachments FOR EACH STATEMENT EXECUTE FUNCTION public.protect_stored_attachment_file();


--
-- Name: active_storage_attachments active_storage_attachments_protect_stored; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER active_storage_attachments_protect_stored BEFORE DELETE OR UPDATE ON public.active_storage_attachments FOR EACH ROW EXECUTE FUNCTION public.protect_stored_attachment_file();


--
-- Name: active_storage_blobs active_storage_blobs_no_stored_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER active_storage_blobs_no_stored_truncate BEFORE TRUNCATE ON public.active_storage_blobs FOR EACH STATEMENT EXECUTE FUNCTION public.protect_stored_attachment_file();


--
-- Name: active_storage_blobs active_storage_blobs_protect_stored; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER active_storage_blobs_protect_stored BEFORE DELETE OR UPDATE ON public.active_storage_blobs FOR EACH ROW EXECUTE FUNCTION public.protect_stored_attachment_file();


--
-- Name: agent_profile_versions agent_profile_versions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER agent_profile_versions_append_only BEFORE DELETE OR UPDATE ON public.agent_profile_versions FOR EACH ROW EXECUTE FUNCTION public.protect_agent_profile_version();


--
-- Name: agent_profile_versions agent_profile_versions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER agent_profile_versions_no_truncate BEFORE TRUNCATE ON public.agent_profile_versions FOR EACH STATEMENT EXECUTE FUNCTION public.protect_agent_profile_version();


--
-- Name: agent_profile_versions agent_profile_versions_validate_policy; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER agent_profile_versions_validate_policy BEFORE INSERT ON public.agent_profile_versions FOR EACH ROW EXECUTE FUNCTION public.validate_agent_profile_version();


--
-- Name: agent_profiles agent_profiles_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER agent_profiles_no_truncate BEFORE TRUNCATE ON public.agent_profiles FOR EACH STATEMENT EXECUTE FUNCTION public.protect_agent_profile();


--
-- Name: agent_profiles agent_profiles_protect_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER agent_profiles_protect_record BEFORE DELETE OR UPDATE ON public.agent_profiles FOR EACH ROW EXECUTE FUNCTION public.protect_agent_profile();


--
-- Name: agent_profiles agent_profiles_require_current_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER agent_profiles_require_current_version AFTER INSERT OR UPDATE ON public.agent_profiles DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.require_current_agent_profile_version();


--
-- Name: agent_profiles agent_profiles_validate_identity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER agent_profiles_validate_identity BEFORE INSERT ON public.agent_profiles FOR EACH ROW EXECUTE FUNCTION public.validate_agent_profile_identity();


--
-- Name: audit_events audit_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_append_only BEFORE DELETE OR UPDATE ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_event_mutation();


--
-- Name: audit_events audit_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON public.audit_events FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_audit_event_mutation();


--
-- Name: case_notes case_notes_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER case_notes_append_only BEFORE DELETE OR UPDATE ON public.case_notes FOR EACH ROW EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: case_notes case_notes_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER case_notes_no_truncate BEFORE TRUNCATE ON public.case_notes FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: conversation_message_attachments conversation_message_attachments_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER conversation_message_attachments_append_only BEFORE DELETE OR UPDATE ON public.conversation_message_attachments FOR EACH ROW EXECUTE FUNCTION public.protect_attachment_join();


--
-- Name: conversation_message_attachments conversation_message_attachments_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER conversation_message_attachments_no_truncate BEFORE TRUNCATE ON public.conversation_message_attachments FOR EACH STATEMENT EXECUTE FUNCTION public.protect_attachment_join();


--
-- Name: conversation_messages conversation_messages_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER conversation_messages_append_only BEFORE DELETE OR UPDATE ON public.conversation_messages FOR EACH ROW EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: conversation_messages conversation_messages_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER conversation_messages_no_truncate BEFORE TRUNCATE ON public.conversation_messages FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: crew_artifacts crew_artifacts_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_artifacts_append_only BEFORE DELETE OR UPDATE ON public.crew_artifacts FOR EACH ROW EXECUTE FUNCTION public.protect_crew_artifact();


--
-- Name: crew_artifacts crew_artifacts_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_artifacts_no_truncate BEFORE TRUNCATE ON public.crew_artifacts FOR EACH STATEMENT EXECUTE FUNCTION public.protect_crew_artifact();


--
-- Name: crew_task_dependencies crew_task_dependencies_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_task_dependencies_append_only BEFORE DELETE OR UPDATE ON public.crew_task_dependencies FOR EACH ROW EXECUTE FUNCTION public.protect_crew_task_dependency();


--
-- Name: crew_task_dependencies crew_task_dependencies_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_task_dependencies_no_truncate BEFORE TRUNCATE ON public.crew_task_dependencies FOR EACH STATEMENT EXECUTE FUNCTION public.protect_crew_task_dependency();


--
-- Name: crew_task_dependencies crew_task_dependencies_validate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_task_dependencies_validate BEFORE INSERT ON public.crew_task_dependencies FOR EACH ROW EXECUTE FUNCTION public.validate_crew_task_dependency();


--
-- Name: crew_task_events crew_task_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_task_events_append_only BEFORE DELETE OR UPDATE ON public.crew_task_events FOR EACH ROW EXECUTE FUNCTION public.protect_crew_task_event();


--
-- Name: crew_task_events crew_task_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_task_events_no_truncate BEFORE TRUNCATE ON public.crew_task_events FOR EACH STATEMENT EXECUTE FUNCTION public.protect_crew_task_event();


--
-- Name: crew_task_events crew_task_events_require_link; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER crew_task_events_require_link AFTER INSERT ON public.crew_task_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.require_linked_crew_task_event();


--
-- Name: crew_tasks crew_tasks_governed_policy_projection; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_tasks_governed_policy_projection BEFORE UPDATE ON public.crew_tasks FOR EACH ROW EXECUTE FUNCTION public.validate_governed_crew_task_projection();


--
-- Name: crew_tasks crew_tasks_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_tasks_no_truncate BEFORE TRUNCATE ON public.crew_tasks FOR EACH STATEMENT EXECUTE FUNCTION public.protect_crew_task();


--
-- Name: crew_tasks crew_tasks_protect_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_tasks_protect_record BEFORE DELETE OR UPDATE ON public.crew_tasks FOR EACH ROW EXECUTE FUNCTION public.protect_crew_task();


--
-- Name: crew_tasks crew_tasks_require_current_event; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER crew_tasks_require_current_event AFTER INSERT OR UPDATE ON public.crew_tasks DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.require_current_crew_task_event();


--
-- Name: crew_templates crew_templates_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_templates_no_truncate BEFORE TRUNCATE ON public.crew_templates FOR EACH STATEMENT EXECUTE FUNCTION public.protect_crew_template();


--
-- Name: crew_templates crew_templates_protect_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER crew_templates_protect_record BEFORE DELETE OR UPDATE ON public.crew_templates FOR EACH ROW EXECUTE FUNCTION public.protect_crew_template();


--
-- Name: customer_success_interventions customer_success_interventions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER customer_success_interventions_no_truncate BEFORE TRUNCATE ON public.customer_success_interventions FOR EACH STATEMENT EXECUTE FUNCTION public.protect_customer_success_intervention();


--
-- Name: customer_success_interventions customer_success_interventions_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER customer_success_interventions_transition BEFORE DELETE OR UPDATE ON public.customer_success_interventions FOR EACH ROW EXECUTE FUNCTION public.protect_customer_success_intervention();


--
-- Name: customer_success_intervention_outcome_reviews customer_success_outcome_reviews_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER customer_success_outcome_reviews_append_only BEFORE DELETE OR UPDATE ON public.customer_success_intervention_outcome_reviews FOR EACH ROW EXECUTE FUNCTION public.protect_customer_success_outcome_review();


--
-- Name: customer_success_intervention_outcome_reviews customer_success_outcome_reviews_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER customer_success_outcome_reviews_no_truncate BEFORE TRUNCATE ON public.customer_success_intervention_outcome_reviews FOR EACH STATEMENT EXECUTE FUNCTION public.protect_customer_success_outcome_review();


--
-- Name: email_message_links email_message_links_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER email_message_links_append_only BEFORE DELETE OR UPDATE ON public.email_message_links FOR EACH ROW EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: email_message_links email_message_links_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER email_message_links_no_truncate BEFORE TRUNCATE ON public.email_message_links FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: email_threads email_threads_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER email_threads_append_only BEFORE DELETE OR UPDATE ON public.email_threads FOR EACH ROW EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: email_threads email_threads_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER email_threads_no_truncate BEFORE TRUNCATE ON public.email_threads FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: execution_events execution_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_events_append_only BEFORE DELETE OR UPDATE ON public.execution_events FOR EACH ROW EXECUTE FUNCTION public.protect_execution_event();


--
-- Name: execution_events execution_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_events_no_truncate BEFORE TRUNCATE ON public.execution_events FOR EACH STATEMENT EXECUTE FUNCTION public.protect_execution_event();


--
-- Name: execution_events execution_events_require_link; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER execution_events_require_link AFTER INSERT ON public.execution_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.require_linked_execution_event();


--
-- Name: execution_memory_selections execution_memory_selections_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_memory_selections_append_only BEFORE DELETE OR UPDATE ON public.execution_memory_selections FOR EACH ROW EXECUTE FUNCTION public.protect_execution_memory_selection();


--
-- Name: execution_memory_selections execution_memory_selections_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_memory_selections_no_truncate BEFORE TRUNCATE ON public.execution_memory_selections FOR EACH STATEMENT EXECUTE FUNCTION public.protect_execution_memory_selection();


--
-- Name: execution_runs execution_personal_account; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_personal_account BEFORE INSERT OR UPDATE ON public.execution_runs FOR EACH ROW EXECUTE FUNCTION public.protect_execution_personal_account();


--
-- Name: execution_runs execution_runs_immutable_context; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_runs_immutable_context BEFORE UPDATE ON public.execution_runs FOR EACH ROW EXECUTE FUNCTION public.protect_execution_run_context();


--
-- Name: execution_runs execution_runs_memory_context_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_runs_memory_context_immutable BEFORE UPDATE ON public.execution_runs FOR EACH ROW EXECUTE FUNCTION public.protect_execution_run_memory_context();


--
-- Name: execution_runs execution_runs_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_runs_no_truncate BEFORE TRUNCATE ON public.execution_runs FOR EACH STATEMENT EXECUTE FUNCTION public.protect_execution_run();


--
-- Name: execution_runs execution_runs_protect_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_runs_protect_record BEFORE DELETE OR UPDATE ON public.execution_runs FOR EACH ROW EXECUTE FUNCTION public.protect_execution_run();


--
-- Name: execution_runs execution_runs_protect_routing; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_runs_protect_routing BEFORE UPDATE ON public.execution_runs FOR EACH ROW EXECUTE FUNCTION public.protect_execution_routing_snapshot();


--
-- Name: execution_runs execution_runs_usage_rate_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER execution_runs_usage_rate_immutable BEFORE UPDATE ON public.execution_runs FOR EACH ROW EXECUTE FUNCTION public.protect_execution_usage_rate();


--
-- Name: governed_policy_previews governed_policy_previews_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER governed_policy_previews_append_only BEFORE DELETE OR UPDATE ON public.governed_policy_previews FOR EACH ROW EXECUTE FUNCTION public.protect_governed_policy_preview();


--
-- Name: governed_policy_previews governed_policy_previews_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER governed_policy_previews_no_truncate BEFORE TRUNCATE ON public.governed_policy_previews FOR EACH STATEMENT EXECUTE FUNCTION public.protect_governed_policy_preview();


--
-- Name: governed_policy_proposals governed_policy_proposals_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER governed_policy_proposals_append_only BEFORE DELETE OR UPDATE ON public.governed_policy_proposals FOR EACH ROW EXECUTE FUNCTION public.protect_governed_policy_proposal();


--
-- Name: governed_policy_proposals governed_policy_proposals_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER governed_policy_proposals_no_truncate BEFORE TRUNCATE ON public.governed_policy_proposals FOR EACH STATEMENT EXECUTE FUNCTION public.protect_governed_policy_proposal();


--
-- Name: governed_policy_proposals governed_policy_proposals_subject_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER governed_policy_proposals_subject_count AFTER INSERT ON public.governed_policy_proposals DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_governed_policy_proposal_subject_count();


--
-- Name: governed_policy_publications governed_policy_publications_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER governed_policy_publications_append_only BEFORE DELETE OR UPDATE ON public.governed_policy_publications FOR EACH ROW EXECUTE FUNCTION public.protect_governed_policy_publication();


--
-- Name: governed_policy_publications governed_policy_publications_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER governed_policy_publications_integrity BEFORE INSERT ON public.governed_policy_publications FOR EACH ROW EXECUTE FUNCTION public.validate_governed_policy_publication();


--
-- Name: governed_policy_publications governed_policy_publications_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER governed_policy_publications_no_truncate BEFORE TRUNCATE ON public.governed_policy_publications FOR EACH STATEMENT EXECUTE FUNCTION public.protect_governed_policy_publication();


--
-- Name: governed_policy_subjects governed_policy_subjects_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER governed_policy_subjects_append_only BEFORE DELETE OR UPDATE ON public.governed_policy_subjects FOR EACH ROW EXECUTE FUNCTION public.protect_governed_policy_subject();


--
-- Name: governed_policy_subjects governed_policy_subjects_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER governed_policy_subjects_count AFTER INSERT OR DELETE OR UPDATE ON public.governed_policy_subjects DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_governed_policy_subject_count();


--
-- Name: governed_policy_subjects governed_policy_subjects_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER governed_policy_subjects_no_truncate BEFORE TRUNCATE ON public.governed_policy_subjects FOR EACH STATEMENT EXECUTE FUNCTION public.protect_governed_policy_subject();


--
-- Name: health_scorecard_backtests health_scorecard_backtests_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER health_scorecard_backtests_append_only BEFORE DELETE OR UPDATE ON public.health_scorecard_backtests FOR EACH ROW EXECUTE FUNCTION public.protect_health_scorecard_record();


--
-- Name: health_scorecard_backtests health_scorecard_backtests_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER health_scorecard_backtests_no_truncate BEFORE TRUNCATE ON public.health_scorecard_backtests FOR EACH STATEMENT EXECUTE FUNCTION public.protect_health_scorecard_record();


--
-- Name: health_scorecard_design_turns health_scorecard_design_turns_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER health_scorecard_design_turns_append_only BEFORE DELETE OR UPDATE ON public.health_scorecard_design_turns FOR EACH ROW EXECUTE FUNCTION public.protect_health_scorecard_record();


--
-- Name: health_scorecard_design_turns health_scorecard_design_turns_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER health_scorecard_design_turns_no_truncate BEFORE TRUNCATE ON public.health_scorecard_design_turns FOR EACH STATEMENT EXECUTE FUNCTION public.protect_health_scorecard_record();


--
-- Name: health_scorecard_versions health_scorecard_versions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER health_scorecard_versions_append_only BEFORE DELETE OR UPDATE ON public.health_scorecard_versions FOR EACH ROW EXECUTE FUNCTION public.protect_health_scorecard_record();


--
-- Name: health_scorecard_versions health_scorecard_versions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER health_scorecard_versions_no_truncate BEFORE TRUNCATE ON public.health_scorecard_versions FOR EACH STATEMENT EXECUTE FUNCTION public.protect_health_scorecard_record();


--
-- Name: health_scorecards health_scorecards_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER health_scorecards_no_truncate BEFORE TRUNCATE ON public.health_scorecards FOR EACH STATEMENT EXECUTE FUNCTION public.protect_health_scorecard_record();


--
-- Name: health_scorecards health_scorecards_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER health_scorecards_protect BEFORE DELETE OR UPDATE ON public.health_scorecards FOR EACH ROW EXECUTE FUNCTION public.protect_health_scorecard_record();


--
-- Name: inbound_email_deliveries inbound_email_deliveries_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER inbound_email_deliveries_no_truncate BEFORE TRUNCATE ON public.inbound_email_deliveries FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_inbound_email_source_mutation();


--
-- Name: inbound_email_deliveries inbound_email_deliveries_protect_source; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER inbound_email_deliveries_protect_source BEFORE DELETE OR UPDATE ON public.inbound_email_deliveries FOR EACH ROW EXECUTE FUNCTION public.prevent_inbound_email_source_mutation();


--
-- Name: intercom_outbound_deliveries intercom_outbound_deliveries_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER intercom_outbound_deliveries_no_truncate BEFORE TRUNCATE ON public.intercom_outbound_deliveries FOR EACH STATEMENT EXECUTE FUNCTION public.protect_intercom_outbound_delivery();


--
-- Name: intercom_outbound_deliveries intercom_outbound_deliveries_protect_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER intercom_outbound_deliveries_protect_record BEFORE DELETE OR UPDATE ON public.intercom_outbound_deliveries FOR EACH ROW EXECUTE FUNCTION public.protect_intercom_outbound_delivery();


--
-- Name: intercom_sync_operations intercom_sync_operations_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER intercom_sync_operations_no_truncate BEFORE TRUNCATE ON public.intercom_sync_operations FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_intercom_sync_operation_mutation();


--
-- Name: intercom_sync_operations intercom_sync_operations_protect_source; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER intercom_sync_operations_protect_source BEFORE DELETE OR UPDATE ON public.intercom_sync_operations FOR EACH ROW EXECUTE FUNCTION public.prevent_intercom_sync_operation_mutation();


--
-- Name: intercom_webhook_deliveries intercom_webhook_deliveries_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER intercom_webhook_deliveries_no_truncate BEFORE TRUNCATE ON public.intercom_webhook_deliveries FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_intercom_webhook_source_mutation();


--
-- Name: intercom_webhook_deliveries intercom_webhook_deliveries_protect_source; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER intercom_webhook_deliveries_protect_source BEFORE DELETE OR UPDATE ON public.intercom_webhook_deliveries FOR EACH ROW EXECUTE FUNCTION public.prevent_intercom_webhook_source_mutation();


--
-- Name: knowledge_source_versions knowledge_source_versions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_source_versions_append_only BEFORE DELETE OR UPDATE ON public.knowledge_source_versions FOR EACH ROW EXECUTE FUNCTION public.protect_knowledge_source_version();


--
-- Name: knowledge_source_versions knowledge_source_versions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_source_versions_no_truncate BEFORE TRUNCATE ON public.knowledge_source_versions FOR EACH STATEMENT EXECUTE FUNCTION public.protect_knowledge_source_version();


--
-- Name: knowledge_source_versions knowledge_source_versions_require_active_source; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_source_versions_require_active_source BEFORE INSERT ON public.knowledge_source_versions FOR EACH ROW EXECUTE FUNCTION public.enforce_active_knowledge_source();


--
-- Name: knowledge_sources knowledge_sources_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_sources_no_truncate BEFORE TRUNCATE ON public.knowledge_sources FOR EACH STATEMENT EXECUTE FUNCTION public.protect_knowledge_source();


--
-- Name: knowledge_sources knowledge_sources_notion_origin; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_sources_notion_origin BEFORE UPDATE ON public.knowledge_sources FOR EACH ROW EXECUTE FUNCTION public.protect_notion_knowledge_origin();


--
-- Name: knowledge_sources knowledge_sources_origin; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_sources_origin BEFORE UPDATE ON public.knowledge_sources FOR EACH ROW EXECUTE FUNCTION public.protect_knowledge_origin();


--
-- Name: knowledge_sources knowledge_sources_protect_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_sources_protect_record BEFORE DELETE OR UPDATE ON public.knowledge_sources FOR EACH ROW EXECUTE FUNCTION public.protect_knowledge_source();


--
-- Name: knowledge_sources knowledge_sources_require_current_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER knowledge_sources_require_current_version AFTER INSERT OR UPDATE ON public.knowledge_sources DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.require_current_knowledge_version();


--
-- Name: memory_correction_proposals memory_correction_proposals_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_correction_proposals_no_truncate BEFORE TRUNCATE ON public.memory_correction_proposals FOR EACH STATEMENT EXECUTE FUNCTION public.protect_memory_correction_proposal();


--
-- Name: memory_correction_proposals memory_correction_proposals_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_correction_proposals_protect BEFORE DELETE OR UPDATE ON public.memory_correction_proposals FOR EACH ROW EXECUTE FUNCTION public.protect_memory_correction_proposal();


--
-- Name: memory_index_entries memory_index_entries_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_index_entries_no_truncate BEFORE TRUNCATE ON public.memory_index_entries FOR EACH STATEMENT EXECUTE FUNCTION public.protect_memory_index_entry();


--
-- Name: memory_index_entries memory_index_entries_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_index_entries_protect BEFORE DELETE OR UPDATE ON public.memory_index_entries FOR EACH ROW EXECUTE FUNCTION public.protect_memory_index_entry();


--
-- Name: memory_proposals memory_proposals_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_proposals_no_truncate BEFORE TRUNCATE ON public.memory_proposals FOR EACH STATEMENT EXECUTE FUNCTION public.protect_memory_proposal();


--
-- Name: memory_proposals memory_proposals_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_proposals_protect BEFORE DELETE OR UPDATE ON public.memory_proposals FOR EACH ROW EXECUTE FUNCTION public.protect_memory_proposal();


--
-- Name: memory_records memory_records_contract; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_records_contract BEFORE INSERT OR DELETE OR UPDATE ON public.memory_records FOR EACH ROW EXECUTE FUNCTION public.protect_memory_record();


--
-- Name: memory_records memory_records_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_records_no_truncate BEFORE TRUNCATE ON public.memory_records FOR EACH STATEMENT EXECUTE FUNCTION public.protect_memory_record();


--
-- Name: memory_tombstones memory_tombstones_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_tombstones_no_truncate BEFORE TRUNCATE ON public.memory_tombstones FOR EACH STATEMENT EXECUTE FUNCTION public.protect_memory_tombstone();


--
-- Name: memory_tombstones memory_tombstones_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_tombstones_protect BEFORE DELETE OR UPDATE ON public.memory_tombstones FOR EACH ROW EXECUTE FUNCTION public.protect_memory_tombstone();


--
-- Name: notifications notifications_require_workspace_event; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER notifications_require_workspace_event BEFORE INSERT OR UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION public.enforce_notification_event_workspace();


--
-- Name: operational_checks operational_checks_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER operational_checks_append_only BEFORE DELETE OR UPDATE ON public.operational_checks FOR EACH ROW EXECUTE FUNCTION public.protect_operational_check();


--
-- Name: operational_checks operational_checks_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER operational_checks_no_truncate BEFORE TRUNCATE ON public.operational_checks FOR EACH STATEMENT EXECUTE FUNCTION public.protect_operational_check();


--
-- Name: outbound_email_deliveries outbound_email_deliveries_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER outbound_email_deliveries_no_truncate BEFORE TRUNCATE ON public.outbound_email_deliveries FOR EACH STATEMENT EXECUTE FUNCTION public.protect_outbound_email_delivery();


--
-- Name: outbound_email_deliveries outbound_email_deliveries_protect_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER outbound_email_deliveries_protect_record BEFORE DELETE OR UPDATE ON public.outbound_email_deliveries FOR EACH ROW EXECUTE FUNCTION public.protect_outbound_email_delivery();


--
-- Name: outbound_email_delivery_attachments outbound_email_delivery_attachments_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER outbound_email_delivery_attachments_append_only BEFORE DELETE OR UPDATE ON public.outbound_email_delivery_attachments FOR EACH ROW EXECUTE FUNCTION public.protect_attachment_join();


--
-- Name: outbound_email_delivery_attachments outbound_email_delivery_attachments_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER outbound_email_delivery_attachments_no_truncate BEFORE TRUNCATE ON public.outbound_email_delivery_attachments FOR EACH STATEMENT EXECUTE FUNCTION public.protect_attachment_join();


--
-- Name: outbound_email_delivery_attachments outbound_email_delivery_attachments_require_clean; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER outbound_email_delivery_attachments_require_clean BEFORE INSERT ON public.outbound_email_delivery_attachments FOR EACH ROW EXECUTE FUNCTION public.enforce_clean_outbound_attachment();


--
-- Name: conversation_message_attachments outbound_message_attachments_require_clean; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER outbound_message_attachments_require_clean BEFORE INSERT ON public.conversation_message_attachments FOR EACH ROW EXECUTE FUNCTION public.enforce_clean_outbound_attachment();


--
-- Name: outbound_webhook_deliveries outbound_webhook_deliveries_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER outbound_webhook_deliveries_protect BEFORE DELETE OR UPDATE ON public.outbound_webhook_deliveries FOR EACH ROW EXECUTE FUNCTION public.protect_outbound_webhook_delivery();


--
-- Name: personal_provider_accounts personal_provider_identity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER personal_provider_identity BEFORE UPDATE ON public.personal_provider_accounts FOR EACH ROW EXECUTE FUNCTION public.protect_personal_provider_identity();


--
-- Name: public_web_extractions public_web_extractions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER public_web_extractions_no_truncate BEFORE TRUNCATE ON public.public_web_extractions FOR EACH STATEMENT EXECUTE FUNCTION public.protect_public_web_extraction();


--
-- Name: public_web_extractions public_web_extractions_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER public_web_extractions_protect BEFORE DELETE OR UPDATE ON public.public_web_extractions FOR EACH ROW EXECUTE FUNCTION public.protect_public_web_extraction();


--
-- Name: public_web_search_results public_web_search_results_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER public_web_search_results_no_truncate BEFORE TRUNCATE ON public.public_web_search_results FOR EACH STATEMENT EXECUTE FUNCTION public.protect_public_web_search_result();


--
-- Name: public_web_search_results public_web_search_results_no_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER public_web_search_results_no_update BEFORE INSERT OR DELETE OR UPDATE ON public.public_web_search_results FOR EACH ROW EXECUTE FUNCTION public.protect_public_web_search_result();


--
-- Name: public_web_searches public_web_searches_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER public_web_searches_no_truncate BEFORE TRUNCATE ON public.public_web_searches FOR EACH STATEMENT EXECUTE FUNCTION public.protect_public_web_search();


--
-- Name: public_web_searches public_web_searches_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER public_web_searches_protect BEFORE DELETE OR UPDATE ON public.public_web_searches FOR EACH ROW EXECUTE FUNCTION public.protect_public_web_search();


--
-- Name: public_web_searches public_web_searches_usage_rate_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER public_web_searches_usage_rate_immutable BEFORE UPDATE ON public.public_web_searches FOR EACH ROW EXECUTE FUNCTION public.protect_public_web_search_usage_rate();


--
-- Name: resolution_contract_families resolution_contract_families_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER resolution_contract_families_no_truncate BEFORE TRUNCATE ON public.resolution_contract_families FOR EACH STATEMENT EXECUTE FUNCTION public.protect_resolution_contract_family();


--
-- Name: resolution_contract_families resolution_contract_families_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER resolution_contract_families_protect BEFORE DELETE OR UPDATE ON public.resolution_contract_families FOR EACH ROW EXECUTE FUNCTION public.protect_resolution_contract_family();


--
-- Name: resolution_contract_families resolution_contract_families_require_published; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER resolution_contract_families_require_published AFTER INSERT OR UPDATE ON public.resolution_contract_families DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_resolution_contract_family_published();


--
-- Name: resolution_contract_versions resolution_contract_versions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER resolution_contract_versions_append_only BEFORE DELETE OR UPDATE ON public.resolution_contract_versions FOR EACH ROW EXECUTE FUNCTION public.protect_resolution_contract_version();


--
-- Name: resolution_contract_versions resolution_contract_versions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER resolution_contract_versions_no_truncate BEFORE TRUNCATE ON public.resolution_contract_versions FOR EACH STATEMENT EXECUTE FUNCTION public.protect_resolution_contract_version();


--
-- Name: runtime_installations runtime_installations_validate_policy; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER runtime_installations_validate_policy BEFORE INSERT OR UPDATE ON public.runtime_installations FOR EACH ROW EXECUTE FUNCTION public.validate_runtime_installation();


--
-- Name: runtime_installations runtime_installations_validate_routing; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER runtime_installations_validate_routing BEFORE INSERT OR UPDATE ON public.runtime_installations FOR EACH ROW EXECUTE FUNCTION public.validate_runtime_routing_policy();


--
-- Name: public_web_searches search_provider_selection_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER search_provider_selection_immutable BEFORE UPDATE ON public.public_web_searches FOR EACH ROW EXECUTE FUNCTION public.protect_search_provider_selection();


--
-- Name: service_calendar_holidays service_calendar_holidays_protect_used_settings; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER service_calendar_holidays_protect_used_settings BEFORE INSERT OR DELETE OR UPDATE ON public.service_calendar_holidays FOR EACH ROW EXECUTE FUNCTION public.prevent_used_sla_configuration_change();


--
-- Name: service_calendars service_calendars_protect_used_settings; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER service_calendars_protect_used_settings BEFORE DELETE OR UPDATE ON public.service_calendars FOR EACH ROW EXECUTE FUNCTION public.prevent_used_sla_configuration_change();


--
-- Name: sla_policies sla_policies_protect_used_settings; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sla_policies_protect_used_settings BEFORE DELETE OR UPDATE ON public.sla_policies FOR EACH ROW EXECUTE FUNCTION public.prevent_used_sla_configuration_change();


--
-- Name: stored_attachments stored_attachments_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stored_attachments_no_truncate BEFORE TRUNCATE ON public.stored_attachments FOR EACH STATEMENT EXECUTE FUNCTION public.protect_stored_attachment();


--
-- Name: stored_attachments stored_attachments_protect_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stored_attachments_protect_record BEFORE DELETE OR UPDATE ON public.stored_attachments FOR EACH ROW EXECUTE FUNCTION public.protect_stored_attachment();


--
-- Name: support_case_status_changes support_case_status_changes_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER support_case_status_changes_append_only BEFORE DELETE OR UPDATE ON public.support_case_status_changes FOR EACH ROW EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: support_case_status_changes support_case_status_changes_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER support_case_status_changes_no_truncate BEFORE TRUNCATE ON public.support_case_status_changes FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: usage_cost_snapshots usage_cost_snapshots_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER usage_cost_snapshots_append_only BEFORE DELETE OR UPDATE ON public.usage_cost_snapshots FOR EACH ROW EXECUTE FUNCTION public.protect_usage_cost_snapshot();


--
-- Name: usage_cost_snapshots usage_cost_snapshots_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER usage_cost_snapshots_no_truncate BEFORE TRUNCATE ON public.usage_cost_snapshots FOR EACH STATEMENT EXECUTE FUNCTION public.protect_usage_cost_snapshot();


--
-- Name: usage_rate_settings usage_rate_settings_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER usage_rate_settings_no_truncate BEFORE TRUNCATE ON public.usage_rate_settings FOR EACH STATEMENT EXECUTE FUNCTION public.protect_usage_rate_setting();


--
-- Name: usage_rate_settings usage_rate_settings_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER usage_rate_settings_protect BEFORE DELETE OR UPDATE ON public.usage_rate_settings FOR EACH ROW EXECUTE FUNCTION public.protect_usage_rate_setting();


--
-- Name: usage_rate_versions usage_rate_versions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER usage_rate_versions_append_only BEFORE DELETE OR UPDATE ON public.usage_rate_versions FOR EACH ROW EXECUTE FUNCTION public.protect_usage_rate_version();


--
-- Name: usage_rate_versions usage_rate_versions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER usage_rate_versions_no_truncate BEFORE TRUNCATE ON public.usage_rate_versions FOR EACH STATEMENT EXECUTE FUNCTION public.protect_usage_rate_version();


--
-- Name: workspace_tombstones workspace_tombstones_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER workspace_tombstones_no_truncate BEFORE TRUNCATE ON public.workspace_tombstones FOR EACH STATEMENT EXECUTE FUNCTION public.protect_workspace_tombstone();


--
-- Name: workspace_tombstones workspace_tombstones_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER workspace_tombstones_protect BEFORE DELETE OR UPDATE ON public.workspace_tombstones FOR EACH ROW EXECUTE FUNCTION public.protect_workspace_tombstone();


--
-- Name: workspaces workspaces_protect_runner_key; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER workspaces_protect_runner_key BEFORE UPDATE ON public.workspaces FOR EACH ROW EXECUTE FUNCTION public.protect_workspace_runner_key();


--
-- Name: execution_runs execution_runs_personal_identity; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT execution_runs_personal_identity FOREIGN KEY (workspace_id, selected_personal_account_key, requested_by_membership_id) REFERENCES public.personal_provider_accounts(workspace_id, account_key, membership_id);


--
-- Name: account_health_assessments fk_account_health_assessments_previous; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_assessments
    ADD CONSTRAINT fk_account_health_assessments_previous FOREIGN KEY (workspace_id, previous_assessment_id) REFERENCES public.account_health_assessments(workspace_id, id);


--
-- Name: account_health_inputs fk_account_health_inputs_correction; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_inputs
    ADD CONSTRAINT fk_account_health_inputs_correction FOREIGN KEY (workspace_id, account_id, input_key, corrects_account_health_input_id) REFERENCES public.account_health_inputs(workspace_id, account_id, input_key, id);


--
-- Name: account_health_inputs fk_account_health_inputs_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_inputs
    ADD CONSTRAINT fk_account_health_inputs_supplier FOREIGN KEY (workspace_id, supplied_by_membership_id, supplied_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: account_health_signals fk_account_health_signals_assessment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_signals
    ADD CONSTRAINT fk_account_health_signals_assessment FOREIGN KEY (workspace_id, account_health_assessment_id) REFERENCES public.account_health_assessments(workspace_id, id);


--
-- Name: account_merges fk_account_merges_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT fk_account_merges_source FOREIGN KEY (workspace_id, source_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: account_merges fk_account_merges_target; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT fk_account_merges_target FOREIGN KEY (workspace_id, target_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: account_risk_investigations fk_account_risk_investigations_assessment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_risk_investigations
    ADD CONSTRAINT fk_account_risk_investigations_assessment FOREIGN KEY (workspace_id, account_health_assessment_id) REFERENCES public.account_health_assessments(workspace_id, id);


--
-- Name: agent_profiles fk_agent_profiles_current_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profiles
    ADD CONSTRAINT fk_agent_profiles_current_version FOREIGN KEY (workspace_id, id, current_version_id) REFERENCES public.agent_profile_versions(workspace_id, agent_profile_id, id);


--
-- Name: contact_merges fk_contact_merges_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges
    ADD CONSTRAINT fk_contact_merges_source FOREIGN KEY (workspace_id, source_id) REFERENCES public.contacts(workspace_id, id);


--
-- Name: contact_merges fk_contact_merges_target; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges
    ADD CONSTRAINT fk_contact_merges_target FOREIGN KEY (workspace_id, target_id) REFERENCES public.contacts(workspace_id, id);


--
-- Name: conversation_messages fk_conversation_messages_reply; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages
    ADD CONSTRAINT fk_conversation_messages_reply FOREIGN KEY (workspace_id, conversation_id, in_reply_to_id) REFERENCES public.conversation_messages(workspace_id, conversation_id, id);


--
-- Name: crew_artifacts fk_crew_artifacts_exact_governed_policy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts
    ADD CONSTRAINT fk_crew_artifacts_exact_governed_policy FOREIGN KEY (workspace_id, governed_policy_publication_id, resolution_contract_version_id) REFERENCES public.governed_policy_publications(workspace_id, id, resolution_contract_version_id);


--
-- Name: crew_artifacts fk_crew_artifacts_exact_run_policy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts
    ADD CONSTRAINT fk_crew_artifacts_exact_run_policy FOREIGN KEY (workspace_id, execution_run_id, crew_task_id, governed_policy_publication_id, resolution_contract_version_id) REFERENCES public.execution_runs(workspace_id, id, crew_task_id, governed_policy_publication_id, resolution_contract_version_id);


--
-- Name: crew_artifacts fk_crew_artifacts_policy_publication; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts
    ADD CONSTRAINT fk_crew_artifacts_policy_publication FOREIGN KEY (workspace_id, governed_policy_publication_id) REFERENCES public.governed_policy_publications(workspace_id, id);


--
-- Name: crew_artifacts fk_crew_artifacts_resolution_contract; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts
    ADD CONSTRAINT fk_crew_artifacts_resolution_contract FOREIGN KEY (workspace_id, resolution_contract_version_id) REFERENCES public.resolution_contract_versions(workspace_id, id);


--
-- Name: crew_artifacts fk_crew_artifacts_supersedes; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts
    ADD CONSTRAINT fk_crew_artifacts_supersedes FOREIGN KEY (workspace_id, supersedes_artifact_id) REFERENCES public.crew_artifacts(workspace_id, id);


--
-- Name: crew_artifacts fk_crew_artifacts_target; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts
    ADD CONSTRAINT fk_crew_artifacts_target FOREIGN KEY (workspace_id, target_artifact_id) REFERENCES public.crew_artifacts(workspace_id, id);


--
-- Name: crew_task_events fk_crew_task_events_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_crew_task_events_actor FOREIGN KEY (workspace_id, actor_membership_id, actor_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: crew_task_events fk_crew_task_events_from_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_crew_task_events_from_version FOREIGN KEY (workspace_id, from_agent_profile_id, from_agent_profile_version_id) REFERENCES public.agent_profile_versions(workspace_id, agent_profile_id, id);


--
-- Name: crew_task_events fk_crew_task_events_to_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_crew_task_events_to_version FOREIGN KEY (workspace_id, to_agent_profile_id, to_agent_profile_version_id) REFERENCES public.agent_profile_versions(workspace_id, agent_profile_id, id);


--
-- Name: crew_tasks fk_crew_tasks_assigned_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_crew_tasks_assigned_profile FOREIGN KEY (workspace_id, crew_template_id, assigned_agent_profile_id) REFERENCES public.agent_profiles(workspace_id, crew_template_id, id);


--
-- Name: crew_tasks fk_crew_tasks_assigned_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_crew_tasks_assigned_version FOREIGN KEY (workspace_id, assigned_agent_profile_id, assigned_agent_profile_version_id) REFERENCES public.agent_profile_versions(workspace_id, agent_profile_id, id);


--
-- Name: crew_tasks fk_crew_tasks_current_event; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_crew_tasks_current_event FOREIGN KEY (workspace_id, id, current_event_id) REFERENCES public.crew_task_events(workspace_id, crew_task_id, id);


--
-- Name: crew_tasks fk_crew_tasks_exact_governed_policy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_crew_tasks_exact_governed_policy FOREIGN KEY (workspace_id, governed_policy_publication_id, resolution_contract_version_id, assigned_agent_profile_version_id) REFERENCES public.governed_policy_publications(workspace_id, id, resolution_contract_version_id, agent_profile_version_id);


--
-- Name: crew_tasks fk_crew_tasks_owner; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_crew_tasks_owner FOREIGN KEY (workspace_id, owner_membership_id, owner_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: crew_tasks fk_crew_tasks_policy_contract; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_crew_tasks_policy_contract FOREIGN KEY (workspace_id, resolution_contract_version_id) REFERENCES public.resolution_contract_versions(workspace_id, id);


--
-- Name: crew_tasks fk_crew_tasks_policy_publication; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_crew_tasks_policy_publication FOREIGN KEY (workspace_id, governed_policy_publication_id) REFERENCES public.governed_policy_publications(workspace_id, id);


--
-- Name: customer_success_interventions fk_cs_interventions_abandoned_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT fk_cs_interventions_abandoned_by FOREIGN KEY (workspace_id, abandoned_by_membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: customer_success_interventions fk_cs_interventions_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT fk_cs_interventions_account FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: customer_success_interventions fk_cs_interventions_accountable; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT fk_cs_interventions_accountable FOREIGN KEY (workspace_id, accountable_membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: customer_success_interventions fk_cs_interventions_approved_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT fk_cs_interventions_approved_by FOREIGN KEY (workspace_id, approved_by_membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: customer_success_interventions fk_cs_interventions_artifact; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT fk_cs_interventions_artifact FOREIGN KEY (workspace_id, proposing_crew_artifact_id) REFERENCES public.crew_artifacts(workspace_id, id);


--
-- Name: customer_success_interventions fk_cs_interventions_assessment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT fk_cs_interventions_assessment FOREIGN KEY (workspace_id, account_health_assessment_id) REFERENCES public.account_health_assessments(workspace_id, id);


--
-- Name: customer_success_interventions fk_cs_interventions_completed_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT fk_cs_interventions_completed_by FOREIGN KEY (workspace_id, completed_by_membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: customer_success_interventions fk_cs_interventions_investigation; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT fk_cs_interventions_investigation FOREIGN KEY (workspace_id, account_risk_investigation_id) REFERENCES public.account_risk_investigations(workspace_id, id);


--
-- Name: customer_success_interventions fk_cs_interventions_proposed_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT fk_cs_interventions_proposed_by FOREIGN KEY (workspace_id, proposed_by_membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: customer_success_intervention_outcome_reviews fk_cs_outcome_reviews_after_assessment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_intervention_outcome_reviews
    ADD CONSTRAINT fk_cs_outcome_reviews_after_assessment FOREIGN KEY (workspace_id, after_account_health_assessment_id) REFERENCES public.account_health_assessments(workspace_id, id);


--
-- Name: customer_success_intervention_outcome_reviews fk_cs_outcome_reviews_before_assessment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_intervention_outcome_reviews
    ADD CONSTRAINT fk_cs_outcome_reviews_before_assessment FOREIGN KEY (workspace_id, before_account_health_assessment_id) REFERENCES public.account_health_assessments(workspace_id, id);


--
-- Name: customer_success_intervention_outcome_reviews fk_cs_outcome_reviews_intervention; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_intervention_outcome_reviews
    ADD CONSTRAINT fk_cs_outcome_reviews_intervention FOREIGN KEY (workspace_id, customer_success_intervention_id) REFERENCES public.customer_success_interventions(workspace_id, id);


--
-- Name: customer_success_intervention_outcome_reviews fk_cs_outcome_reviews_reviewer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_intervention_outcome_reviews
    ADD CONSTRAINT fk_cs_outcome_reviews_reviewer FOREIGN KEY (workspace_id, reviewed_by_membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: email_drafts fk_email_drafts_human_editor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_email_drafts_human_editor FOREIGN KEY (workspace_id, human_edited_by_membership_id, human_edited_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: email_drafts fk_email_drafts_human_editor_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_email_drafts_human_editor_user FOREIGN KEY (human_edited_by_user_id) REFERENCES public.users(id);


--
-- Name: email_drafts fk_email_drafts_source_artifact; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_email_drafts_source_artifact FOREIGN KEY (workspace_id, source_crew_artifact_id) REFERENCES public.crew_artifacts(workspace_id, id);


--
-- Name: execution_runs fk_execution_runs_current_event; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_execution_runs_current_event FOREIGN KEY (workspace_id, id, current_event_id) REFERENCES public.execution_events(workspace_id, execution_run_id, id);


--
-- Name: execution_runs fk_execution_runs_exact_governed_policy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_execution_runs_exact_governed_policy FOREIGN KEY (workspace_id, governed_policy_publication_id, resolution_contract_version_id, agent_profile_version_id) REFERENCES public.governed_policy_publications(workspace_id, id, resolution_contract_version_id, agent_profile_version_id);


--
-- Name: execution_runs fk_execution_runs_exact_task_policy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_execution_runs_exact_task_policy FOREIGN KEY (workspace_id, crew_task_id, governed_policy_publication_id, resolution_contract_version_id, agent_profile_version_id) REFERENCES public.crew_tasks(workspace_id, id, governed_policy_publication_id, resolution_contract_version_id, assigned_agent_profile_version_id);


--
-- Name: execution_runs fk_execution_runs_input_artifact; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_execution_runs_input_artifact FOREIGN KEY (workspace_id, input_artifact_id) REFERENCES public.crew_artifacts(workspace_id, id);


--
-- Name: execution_runs fk_execution_runs_policy_contract; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_execution_runs_policy_contract FOREIGN KEY (workspace_id, resolution_contract_version_id) REFERENCES public.resolution_contract_versions(workspace_id, id);


--
-- Name: execution_runs fk_execution_runs_policy_publication; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_execution_runs_policy_publication FOREIGN KEY (workspace_id, governed_policy_publication_id) REFERENCES public.governed_policy_publications(workspace_id, id);


--
-- Name: execution_runs fk_execution_runs_usage_rate; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_execution_runs_usage_rate FOREIGN KEY (workspace_id, usage_rate_version_id) REFERENCES public.usage_rate_versions(workspace_id, id);


--
-- Name: execution_runs fk_execution_runs_workspace_runtime; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_execution_runs_workspace_runtime FOREIGN KEY (workspace_id, runtime_installation_id) REFERENCES public.runtime_installations(workspace_id, id);


--
-- Name: health_scorecard_versions fk_health_scorecard_versions_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_versions
    ADD CONSTRAINT fk_health_scorecard_versions_actor FOREIGN KEY (workspace_id, created_by_membership_id, created_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: health_scorecards fk_health_scorecards_current_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecards
    ADD CONSTRAINT fk_health_scorecards_current_version FOREIGN KEY (workspace_id, id, current_version_id) REFERENCES public.health_scorecard_versions(workspace_id, health_scorecard_id, id);


--
-- Name: intercom_backfill_batches fk_intercom_backfill_batches_run; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_batches
    ADD CONSTRAINT fk_intercom_backfill_batches_run FOREIGN KEY (workspace_id, intercom_backfill_run_id) REFERENCES public.intercom_backfill_runs(workspace_id, id);


--
-- Name: intercom_backfill_exceptions fk_intercom_backfill_exceptions_identity; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_exceptions
    ADD CONSTRAINT fk_intercom_backfill_exceptions_identity FOREIGN KEY (workspace_id, source_identity_id) REFERENCES public.source_identities(workspace_id, id);


--
-- Name: intercom_backfill_exceptions fk_intercom_backfill_exceptions_manifest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_exceptions
    ADD CONSTRAINT fk_intercom_backfill_exceptions_manifest FOREIGN KEY (workspace_id, intercom_backfill_manifest_id) REFERENCES public.intercom_backfill_manifests(workspace_id, id);


--
-- Name: intercom_backfill_exceptions fk_intercom_backfill_exceptions_run; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_exceptions
    ADD CONSTRAINT fk_intercom_backfill_exceptions_run FOREIGN KEY (workspace_id, intercom_backfill_run_id) REFERENCES public.intercom_backfill_runs(workspace_id, id);


--
-- Name: intercom_backfill_manifests fk_intercom_backfill_manifests_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_manifests
    ADD CONSTRAINT fk_intercom_backfill_manifests_actor FOREIGN KEY (workspace_id, created_by_membership_id, created_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: intercom_backfill_manifests fk_intercom_backfill_manifests_connection; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_manifests
    ADD CONSTRAINT fk_intercom_backfill_manifests_connection FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: intercom_backfill_reports fk_intercom_backfill_reports_run; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_reports
    ADD CONSTRAINT fk_intercom_backfill_reports_run FOREIGN KEY (workspace_id, intercom_backfill_run_id) REFERENCES public.intercom_backfill_runs(workspace_id, id);


--
-- Name: intercom_backfill_runs fk_intercom_backfill_runs_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_runs
    ADD CONSTRAINT fk_intercom_backfill_runs_actor FOREIGN KEY (workspace_id, confirmed_by_membership_id, confirmed_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: intercom_backfill_runs fk_intercom_backfill_runs_connection; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_runs
    ADD CONSTRAINT fk_intercom_backfill_runs_connection FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: intercom_backfill_runs fk_intercom_backfill_runs_manifest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_runs
    ADD CONSTRAINT fk_intercom_backfill_runs_manifest FOREIGN KEY (workspace_id, intercom_backfill_manifest_id) REFERENCES public.intercom_backfill_manifests(workspace_id, id);


--
-- Name: intercom_drafts fk_intercom_drafts_human_editor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_drafts
    ADD CONSTRAINT fk_intercom_drafts_human_editor FOREIGN KEY (workspace_id, human_edited_by_membership_id, human_edited_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: intercom_drafts fk_intercom_drafts_human_editor_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_drafts
    ADD CONSTRAINT fk_intercom_drafts_human_editor_user FOREIGN KEY (human_edited_by_user_id) REFERENCES public.users(id);


--
-- Name: intercom_drafts fk_intercom_drafts_source_artifact; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_drafts
    ADD CONSTRAINT fk_intercom_drafts_source_artifact FOREIGN KEY (workspace_id, source_crew_artifact_id) REFERENCES public.crew_artifacts(workspace_id, id);


--
-- Name: intercom_outbound_deliveries fk_intercom_outbound_deliveries_human_editor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT fk_intercom_outbound_deliveries_human_editor FOREIGN KEY (workspace_id, human_edited_by_membership_id, human_edited_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: intercom_outbound_deliveries fk_intercom_outbound_deliveries_human_editor_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT fk_intercom_outbound_deliveries_human_editor_user FOREIGN KEY (human_edited_by_user_id) REFERENCES public.users(id);


--
-- Name: intercom_outbound_deliveries fk_intercom_outbound_deliveries_source_artifact; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT fk_intercom_outbound_deliveries_source_artifact FOREIGN KEY (workspace_id, source_crew_artifact_id) REFERENCES public.crew_artifacts(workspace_id, id);


--
-- Name: intercom_part_attachments fk_intercom_part_attachments_attachment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_attachments
    ADD CONSTRAINT fk_intercom_part_attachments_attachment FOREIGN KEY (workspace_id, stored_attachment_id) REFERENCES public.stored_attachments(workspace_id, id);


--
-- Name: intercom_part_attachments fk_intercom_part_attachments_part; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_attachments
    ADD CONSTRAINT fk_intercom_part_attachments_part FOREIGN KEY (workspace_id, intercom_part_link_id) REFERENCES public.intercom_part_links(workspace_id, id);


--
-- Name: knowledge_sources fk_knowledge_sources_current_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sources
    ADD CONSTRAINT fk_knowledge_sources_current_version FOREIGN KEY (workspace_id, id, current_version_id) REFERENCES public.knowledge_source_versions(workspace_id, knowledge_source_id, id);


--
-- Name: memory_correction_proposals fk_memory_corrections_proposer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_correction_proposals
    ADD CONSTRAINT fk_memory_corrections_proposer FOREIGN KEY (workspace_id, proposed_by_membership_id, proposed_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: memory_correction_proposals fk_memory_corrections_publication; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_correction_proposals
    ADD CONSTRAINT fk_memory_corrections_publication FOREIGN KEY (workspace_id, published_memory_record_id) REFERENCES public.memory_records(workspace_id, id);


--
-- Name: memory_correction_proposals fk_memory_corrections_reviewer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_correction_proposals
    ADD CONSTRAINT fk_memory_corrections_reviewer FOREIGN KEY (workspace_id, reviewed_by_membership_id, reviewed_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: memory_records fk_memory_records_organization_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_memory_records_organization_workspace FOREIGN KEY (workspace_id, organization_id) REFERENCES public.workspaces(id, organization_id);


--
-- Name: memory_records fk_memory_records_scope_agent; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_memory_records_scope_agent FOREIGN KEY (workspace_id, agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


--
-- Name: memory_records fk_memory_records_scope_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_memory_records_scope_user FOREIGN KEY (workspace_id, user_id) REFERENCES public.memberships(workspace_id, user_id);


--
-- Name: memory_records fk_memory_records_source_agent; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_memory_records_source_agent FOREIGN KEY (workspace_id, source_agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


--
-- Name: memory_records fk_memory_records_source_human; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_memory_records_source_human FOREIGN KEY (workspace_id, source_membership_id, source_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: memory_records fk_memory_records_supersedes; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_memory_records_supersedes FOREIGN KEY (workspace_id, supersedes_memory_record_id) REFERENCES public.memory_records(workspace_id, id);


--
-- Name: memory_tombstones fk_memory_tombstones_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_tombstones
    ADD CONSTRAINT fk_memory_tombstones_actor FOREIGN KEY (workspace_id, deleted_by_membership_id, deleted_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: notifications fk_notifications_workspace_recipient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_notifications_workspace_recipient FOREIGN KEY (workspace_id, recipient_membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: operational_checks fk_operational_checks_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_checks
    ADD CONSTRAINT fk_operational_checks_actor FOREIGN KEY (workspace_id, recorded_by_membership_id, recorded_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: outbound_email_deliveries fk_outbound_email_deliveries_human_editor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_outbound_email_deliveries_human_editor FOREIGN KEY (workspace_id, human_edited_by_membership_id, human_edited_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: outbound_email_deliveries fk_outbound_email_deliveries_human_editor_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_outbound_email_deliveries_human_editor_user FOREIGN KEY (human_edited_by_user_id) REFERENCES public.users(id);


--
-- Name: outbound_email_deliveries fk_outbound_email_deliveries_source_artifact; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_outbound_email_deliveries_source_artifact FOREIGN KEY (workspace_id, source_crew_artifact_id) REFERENCES public.crew_artifacts(workspace_id, id);


--
-- Name: outbound_webhook_deliveries fk_outbound_webhook_delivery_endpoint; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_webhook_deliveries
    ADD CONSTRAINT fk_outbound_webhook_delivery_endpoint FOREIGN KEY (workspace_id, outbound_webhook_endpoint_id) REFERENCES public.outbound_webhook_endpoints(workspace_id, id);


--
-- Name: outbound_webhook_deliveries fk_outbound_webhook_delivery_notification; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_webhook_deliveries
    ADD CONSTRAINT fk_outbound_webhook_delivery_notification FOREIGN KEY (workspace_id, notification_id) REFERENCES public.notifications(workspace_id, id);


--
-- Name: governed_policy_previews fk_policy_previews_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_previews
    ADD CONSTRAINT fk_policy_previews_actor FOREIGN KEY (workspace_id, created_by_membership_id, created_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: governed_policy_previews fk_policy_previews_proposal; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_previews
    ADD CONSTRAINT fk_policy_previews_proposal FOREIGN KEY (workspace_id, governed_policy_proposal_id) REFERENCES public.governed_policy_proposals(workspace_id, id);


--
-- Name: governed_policy_proposals fk_policy_proposals_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals
    ADD CONSTRAINT fk_policy_proposals_actor FOREIGN KEY (workspace_id, created_by_membership_id, created_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: governed_policy_proposals fk_policy_proposals_candidate_contract; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals
    ADD CONSTRAINT fk_policy_proposals_candidate_contract FOREIGN KEY (workspace_id, resolution_contract_version_id) REFERENCES public.resolution_contract_versions(workspace_id, id);


--
-- Name: governed_policy_proposals fk_policy_proposals_candidate_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals
    ADD CONSTRAINT fk_policy_proposals_candidate_profile FOREIGN KEY (workspace_id, agent_profile_id, agent_profile_version_id) REFERENCES public.agent_profile_versions(workspace_id, agent_profile_id, id);


--
-- Name: governed_policy_proposals fk_policy_proposals_family; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals
    ADD CONSTRAINT fk_policy_proposals_family FOREIGN KEY (workspace_id, resolution_contract_family_id) REFERENCES public.resolution_contract_families(workspace_id, id);


--
-- Name: governed_policy_proposals fk_policy_proposals_prior_contract; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals
    ADD CONSTRAINT fk_policy_proposals_prior_contract FOREIGN KEY (workspace_id, prior_resolution_contract_version_id) REFERENCES public.resolution_contract_versions(workspace_id, id);


--
-- Name: governed_policy_proposals fk_policy_proposals_prior_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals
    ADD CONSTRAINT fk_policy_proposals_prior_profile FOREIGN KEY (workspace_id, agent_profile_id, prior_agent_profile_version_id) REFERENCES public.agent_profile_versions(workspace_id, agent_profile_id, id);


--
-- Name: governed_policy_proposals fk_policy_proposals_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals
    ADD CONSTRAINT fk_policy_proposals_profile FOREIGN KEY (workspace_id, agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


--
-- Name: governed_policy_publications fk_policy_publications_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_publications
    ADD CONSTRAINT fk_policy_publications_actor FOREIGN KEY (workspace_id, created_by_membership_id, created_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: governed_policy_publications fk_policy_publications_contract; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_publications
    ADD CONSTRAINT fk_policy_publications_contract FOREIGN KEY (workspace_id, resolution_contract_version_id) REFERENCES public.resolution_contract_versions(workspace_id, id);


--
-- Name: governed_policy_publications fk_policy_publications_preview; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_publications
    ADD CONSTRAINT fk_policy_publications_preview FOREIGN KEY (workspace_id, governed_policy_proposal_id, governed_policy_preview_id) REFERENCES public.governed_policy_previews(workspace_id, governed_policy_proposal_id, id);


--
-- Name: governed_policy_publications fk_policy_publications_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_publications
    ADD CONSTRAINT fk_policy_publications_profile FOREIGN KEY (workspace_id, agent_profile_version_id) REFERENCES public.agent_profile_versions(workspace_id, id);


--
-- Name: governed_policy_publications fk_policy_publications_proposal; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_publications
    ADD CONSTRAINT fk_policy_publications_proposal FOREIGN KEY (workspace_id, governed_policy_proposal_id) REFERENCES public.governed_policy_proposals(workspace_id, id);


--
-- Name: governed_policy_publications fk_policy_publications_supersedes; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_publications
    ADD CONSTRAINT fk_policy_publications_supersedes FOREIGN KEY (workspace_id, supersedes_publication_id) REFERENCES public.governed_policy_publications(workspace_id, id);


--
-- Name: governed_policy_subjects fk_policy_subjects_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_subjects
    ADD CONSTRAINT fk_policy_subjects_account FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: governed_policy_subjects fk_policy_subjects_case; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_subjects
    ADD CONSTRAINT fk_policy_subjects_case FOREIGN KEY (workspace_id, support_case_id) REFERENCES public.support_cases(workspace_id, id);


--
-- Name: governed_policy_subjects fk_policy_subjects_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_subjects
    ADD CONSTRAINT fk_policy_subjects_profile FOREIGN KEY (workspace_id, agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


--
-- Name: governed_policy_subjects fk_policy_subjects_proposal; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_subjects
    ADD CONSTRAINT fk_policy_subjects_proposal FOREIGN KEY (workspace_id, governed_policy_proposal_id) REFERENCES public.governed_policy_proposals(workspace_id, id);


--
-- Name: public_web_searches fk_public_web_searches_usage_rate; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_searches
    ADD CONSTRAINT fk_public_web_searches_usage_rate FOREIGN KEY (workspace_id, usage_rate_version_id) REFERENCES public.usage_rate_versions(workspace_id, id);


--
-- Name: account_merges fk_rails_00215f0be3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT fk_rails_00215f0be3 FOREIGN KEY (unmerged_by_id) REFERENCES public.users(id);


--
-- Name: account_health_inputs fk_rails_008d7a04b1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_inputs
    ADD CONSTRAINT fk_rails_008d7a04b1 FOREIGN KEY (supplied_by_user_id) REFERENCES public.users(id);


--
-- Name: crew_task_dependencies fk_rails_00fd3c8c09; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_dependencies
    ADD CONSTRAINT fk_rails_00fd3c8c09 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: case_slas fk_rails_048a2ba7c7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_slas
    ADD CONSTRAINT fk_rails_048a2ba7c7 FOREIGN KEY (workspace_id, sla_policy_id) REFERENCES public.sla_policies(workspace_id, id);


--
-- Name: agent_profile_versions fk_rails_0584ef2f1b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profile_versions
    ADD CONSTRAINT fk_rails_0584ef2f1b FOREIGN KEY (workspace_id, created_by_membership_id, created_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: intercom_outbound_deliveries fk_rails_09ceab4559; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT fk_rails_09ceab4559 FOREIGN KEY (workspace_id, actor_membership_id, actor_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: agent_profile_versions fk_rails_0a8ca6adb2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profile_versions
    ADD CONSTRAINT fk_rails_0a8ca6adb2 FOREIGN KEY (workspace_id, agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


--
-- Name: account_health_assessments fk_rails_0b433e9580; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_assessments
    ADD CONSTRAINT fk_rails_0b433e9580 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: execution_runs fk_rails_0b449bceac; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_rails_0b449bceac FOREIGN KEY (workspace_id, crew_task_id) REFERENCES public.crew_tasks(workspace_id, id);


--
-- Name: outbound_email_deliveries fk_rails_0e3170a70d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_0e3170a70d FOREIGN KEY (workspace_id, actor_membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: memory_records fk_rails_0e5940f0b0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_rails_0e5940f0b0 FOREIGN KEY (workspace_id, support_case_id) REFERENCES public.support_cases(workspace_id, id);


--
-- Name: health_scorecard_backtests fk_rails_0f66ec7d78; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_backtests
    ADD CONSTRAINT fk_rails_0f66ec7d78 FOREIGN KEY (workspace_id, health_scorecard_version_id) REFERENCES public.health_scorecard_versions(workspace_id, id);


--
-- Name: outbound_email_deliveries fk_rails_1042d38a26; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_1042d38a26 FOREIGN KEY (workspace_id, shared_email_inbox_id) REFERENCES public.shared_email_inboxes(workspace_id, id);


--
-- Name: contact_merges fk_rails_105e45e7a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges
    ADD CONSTRAINT fk_rails_105e45e7a0 FOREIGN KEY (merged_by_id) REFERENCES public.users(id);


--
-- Name: inbound_email_deliveries fk_rails_10f7f74b91; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbound_email_deliveries
    ADD CONSTRAINT fk_rails_10f7f74b91 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: memory_records fk_rails_11138da201; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_rails_11138da201 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: support_case_products fk_rails_116da4b7f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_products
    ADD CONSTRAINT fk_rails_116da4b7f1 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: support_case_products fk_rails_132e560ee1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_products
    ADD CONSTRAINT fk_rails_132e560ee1 FOREIGN KEY (workspace_id, support_case_id) REFERENCES public.support_cases(workspace_id, id);


--
-- Name: personal_provider_accounts fk_rails_1444e811e2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_provider_accounts
    ADD CONSTRAINT fk_rails_1444e811e2 FOREIGN KEY (workspace_id, membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: support_case_taggings fk_rails_1557a3d783; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_taggings
    ADD CONSTRAINT fk_rails_1557a3d783 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: knowledge_source_versions fk_rails_17c1555b4f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_versions
    ADD CONSTRAINT fk_rails_17c1555b4f FOREIGN KEY (workspace_id, knowledge_source_id) REFERENCES public.knowledge_sources(workspace_id, id);


--
-- Name: knowledge_applicability_products fk_rails_189f60d5cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicability_products
    ADD CONSTRAINT fk_rails_189f60d5cf FOREIGN KEY (workspace_id, product_id) REFERENCES public.products(workspace_id, id);


--
-- Name: crew_task_events fk_rails_189fd006fb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_rails_189fd006fb FOREIGN KEY (workspace_id, crew_task_id) REFERENCES public.crew_tasks(workspace_id, id);


--
-- Name: knowledge_applicability_products fk_rails_18c1102e65; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicability_products
    ADD CONSTRAINT fk_rails_18c1102e65 FOREIGN KEY (workspace_id, knowledge_applicability_id) REFERENCES public.knowledge_applicabilities(workspace_id, id);


--
-- Name: public_web_search_results fk_rails_1ab678e4ab; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_search_results
    ADD CONSTRAINT fk_rails_1ab678e4ab FOREIGN KEY (workspace_id, public_web_search_id) REFERENCES public.public_web_searches(workspace_id, id) ON DELETE CASCADE;


--
-- Name: email_drafts fk_rails_1aceaa280f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_rails_1aceaa280f FOREIGN KEY (workspace_id, email_thread_id, conversation_id) REFERENCES public.email_threads(workspace_id, id, conversation_id);


--
-- Name: health_scorecard_versions fk_rails_1ef1d40a69; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_versions
    ADD CONSTRAINT fk_rails_1ef1d40a69 FOREIGN KEY (workspace_id, health_scorecard_id) REFERENCES public.health_scorecards(workspace_id, id);


--
-- Name: governed_policy_proposals fk_rails_1f0cc57d5e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals
    ADD CONSTRAINT fk_rails_1f0cc57d5e FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: intercom_part_links fk_rails_1f0e1f209b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_links
    ADD CONSTRAINT fk_rails_1f0e1f209b FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: intercom_outbound_deliveries fk_rails_21357be27b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT fk_rails_21357be27b FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: governed_policy_publications fk_rails_2301af5828; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_publications
    ADD CONSTRAINT fk_rails_2301af5828 FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: memory_proposals fk_rails_23d39be37f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_proposals
    ADD CONSTRAINT fk_rails_23d39be37f FOREIGN KEY (workspace_id, contact_id) REFERENCES public.contacts(workspace_id, id);


--
-- Name: crew_task_events fk_rails_25fca654f6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_rails_25fca654f6 FOREIGN KEY (actor_user_id) REFERENCES public.users(id);


--
-- Name: memory_proposals fk_rails_26f020daae; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_proposals
    ADD CONSTRAINT fk_rails_26f020daae FOREIGN KEY (workspace_id, support_case_id) REFERENCES public.support_cases(workspace_id, id);


--
-- Name: intercom_webhook_deliveries fk_rails_285c5efc52; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_webhook_deliveries
    ADD CONSTRAINT fk_rails_285c5efc52 FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: service_calendars fk_rails_28a2d1884f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_calendars
    ADD CONSTRAINT fk_rails_28a2d1884f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: execution_runs fk_rails_29f9b8aea0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_rails_29f9b8aea0 FOREIGN KEY (workspace_id, requested_by_membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: support_case_products fk_rails_2b8bde7fba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_products
    ADD CONSTRAINT fk_rails_2b8bde7fba FOREIGN KEY (workspace_id, product_id) REFERENCES public.products(workspace_id, id);


--
-- Name: runtime_installations fk_rails_2d6bafe6cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runtime_installations
    ADD CONSTRAINT fk_rails_2d6bafe6cf FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: intercom_conversation_links fk_rails_2d83c7a76e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_conversation_links
    ADD CONSTRAINT fk_rails_2d83c7a76e FOREIGN KEY (workspace_id, conversation_id, support_case_id) REFERENCES public.support_cases(workspace_id, conversation_id, id);


--
-- Name: workspace_deletion_requests fk_rails_2e13299516; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_deletion_requests
    ADD CONSTRAINT fk_rails_2e13299516 FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


--
-- Name: intercom_outbound_deliveries fk_rails_2ec48d6788; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT fk_rails_2ec48d6788 FOREIGN KEY (workspace_id, conversation_id, conversation_message_id) REFERENCES public.conversation_messages(workspace_id, conversation_id, id);


--
-- Name: memory_records fk_rails_2ec94a5a6b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_rails_2ec94a5a6b FOREIGN KEY (workspace_id, crew_template_id) REFERENCES public.crew_templates(workspace_id, id);


--
-- Name: conversation_messages fk_rails_317b29f039; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages
    ADD CONSTRAINT fk_rails_317b29f039 FOREIGN KEY (workspace_id, conversation_id) REFERENCES public.conversations(workspace_id, id);


--
-- Name: crew_tasks fk_rails_3314bcee7d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_rails_3314bcee7d FOREIGN KEY (workspace_id, support_case_id) REFERENCES public.support_cases(workspace_id, id);


--
-- Name: products fk_rails_33d7228cf4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT fk_rails_33d7228cf4 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: support_cases fk_rails_34c044a23d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_cases
    ADD CONSTRAINT fk_rails_34c044a23d FOREIGN KEY (workspace_id, conversation_id) REFERENCES public.conversations(workspace_id, id);


--
-- Name: tags fk_rails_3633c0c202; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT fk_rails_3633c0c202 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: intercom_sync_operations fk_rails_3699c733a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_sync_operations
    ADD CONSTRAINT fk_rails_3699c733a4 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: intercom_tag_links fk_rails_36b994f919; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_tag_links
    ADD CONSTRAINT fk_rails_36b994f919 FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: outbound_webhook_endpoints fk_rails_36deb0720c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_webhook_endpoints
    ADD CONSTRAINT fk_rails_36deb0720c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: intercom_connections fk_rails_3a3160e258; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_connections
    ADD CONSTRAINT fk_rails_3a3160e258 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: health_scorecard_design_turns fk_rails_3a805638f3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_design_turns
    ADD CONSTRAINT fk_rails_3a805638f3 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: operational_checks fk_rails_3aa5b562c6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_checks
    ADD CONSTRAINT fk_rails_3aa5b562c6 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: health_scorecard_design_turns fk_rails_3bc3ca1f2f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_design_turns
    ADD CONSTRAINT fk_rails_3bc3ca1f2f FOREIGN KEY (workspace_id, health_scorecard_version_id) REFERENCES public.health_scorecard_versions(workspace_id, id);


--
-- Name: memory_correction_proposals fk_rails_3c417b5b0f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_correction_proposals
    ADD CONSTRAINT fk_rails_3c417b5b0f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: memory_proposals fk_rails_3c71138a19; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_proposals
    ADD CONSTRAINT fk_rails_3c71138a19 FOREIGN KEY (workspace_id, source_crew_artifact_id) REFERENCES public.crew_artifacts(workspace_id, id);


--
-- Name: runtime_installations fk_rails_3cc870d257; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runtime_installations
    ADD CONSTRAINT fk_rails_3cc870d257 FOREIGN KEY (approved_by_user_id) REFERENCES public.users(id);


--
-- Name: workspaces fk_rails_3e6d59991e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT fk_rails_3e6d59991e FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: crew_task_dependencies fk_rails_3ebdcac61d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_dependencies
    ADD CONSTRAINT fk_rails_3ebdcac61d FOREIGN KEY (workspace_id, crew_task_id) REFERENCES public.crew_tasks(workspace_id, id);


--
-- Name: service_calendar_holidays fk_rails_3efa0e2453; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_calendar_holidays
    ADD CONSTRAINT fk_rails_3efa0e2453 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: agent_profiles fk_rails_406e779092; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profiles
    ADD CONSTRAINT fk_rails_406e779092 FOREIGN KEY (workspace_id, crew_template_id) REFERENCES public.crew_templates(workspace_id, id);


--
-- Name: support_case_taggings fk_rails_418830fb15; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_taggings
    ADD CONSTRAINT fk_rails_418830fb15 FOREIGN KEY (workspace_id, support_case_id) REFERENCES public.support_cases(workspace_id, id);


--
-- Name: workspace_data_policies fk_rails_419333edb5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_data_policies
    ADD CONSTRAINT fk_rails_419333edb5 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: health_scorecards fk_rails_422df8aa02; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecards
    ADD CONSTRAINT fk_rails_422df8aa02 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: service_calendar_holidays fk_rails_4308962f7b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_calendar_holidays
    ADD CONSTRAINT fk_rails_4308962f7b FOREIGN KEY (workspace_id, service_calendar_id) REFERENCES public.service_calendars(workspace_id, id);


--
-- Name: knowledge_sync_observations fk_rails_432d0248cb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_observations
    ADD CONSTRAINT fk_rails_432d0248cb FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: knowledge_source_versions fk_rails_4502cdedde; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_versions
    ADD CONSTRAINT fk_rails_4502cdedde FOREIGN KEY (workspace_id, created_by_membership_id, created_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: health_scorecard_versions fk_rails_464bd1eeeb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_versions
    ADD CONSTRAINT fk_rails_464bd1eeeb FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: public_web_searches fk_rails_46a5546050; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_searches
    ADD CONSTRAINT fk_rails_46a5546050 FOREIGN KEY (workspace_id, crew_task_id) REFERENCES public.crew_tasks(workspace_id, id) ON DELETE CASCADE;


--
-- Name: case_slas fk_rails_480547c7a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_slas
    ADD CONSTRAINT fk_rails_480547c7a0 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: health_scorecard_backtests fk_rails_49045831df; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_backtests
    ADD CONSTRAINT fk_rails_49045831df FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: execution_events fk_rails_491af79ea7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_events
    ADD CONSTRAINT fk_rails_491af79ea7 FOREIGN KEY (workspace_id, execution_run_id) REFERENCES public.execution_runs(workspace_id, id);


--
-- Name: stored_attachments fk_rails_49367e49f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_attachments
    ADD CONSTRAINT fk_rails_49367e49f1 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: memory_proposals fk_rails_4a0f4103ec; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_proposals
    ADD CONSTRAINT fk_rails_4a0f4103ec FOREIGN KEY (workspace_id, published_memory_record_id) REFERENCES public.memory_records(workspace_id, id);


--
-- Name: workspace_deletion_requests fk_rails_4a9a23408e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_deletion_requests
    ADD CONSTRAINT fk_rails_4a9a23408e FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: account_health_signals fk_rails_4bcf789340; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_signals
    ADD CONSTRAINT fk_rails_4bcf789340 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: sla_escalation_tasks fk_rails_4c05045338; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_escalation_tasks
    ADD CONSTRAINT fk_rails_4c05045338 FOREIGN KEY (workspace_id, case_sla_id) REFERENCES public.case_slas(workspace_id, id);


--
-- Name: outbound_email_delivery_attachments fk_rails_4d393bb9b0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_delivery_attachments
    ADD CONSTRAINT fk_rails_4d393bb9b0 FOREIGN KEY (workspace_id, stored_attachment_id) REFERENCES public.stored_attachments(workspace_id, id);


--
-- Name: crew_tasks fk_rails_4d434544ba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_rails_4d434544ba FOREIGN KEY (workspace_id, crew_template_id) REFERENCES public.crew_templates(workspace_id, id);


--
-- Name: account_merges fk_rails_4f29f8ae3c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT fk_rails_4f29f8ae3c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: execution_events fk_rails_4f443f1b0c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_events
    ADD CONSTRAINT fk_rails_4f443f1b0c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: memory_index_entries fk_rails_4f557f0f42; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_index_entries
    ADD CONSTRAINT fk_rails_4f557f0f42 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: memory_records fk_rails_522a4d29cb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_rails_522a4d29cb FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: integration_oauth_attempts fk_rails_5364f119a8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_oauth_attempts
    ADD CONSTRAINT fk_rails_5364f119a8 FOREIGN KEY (workspace_id, workspace_connector_id) REFERENCES public.workspace_connectors(workspace_id, id) ON DELETE CASCADE;


--
-- Name: health_scorecard_design_turns fk_rails_53922c0c70; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_design_turns
    ADD CONSTRAINT fk_rails_53922c0c70 FOREIGN KEY (workspace_id, membership_id, user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: conversation_message_attachments fk_rails_5474042175; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_message_attachments
    ADD CONSTRAINT fk_rails_5474042175 FOREIGN KEY (workspace_id, conversation_id, conversation_message_id) REFERENCES public.conversation_messages(workspace_id, conversation_id, id);


--
-- Name: intercom_backfill_manifests fk_rails_5525b9fd33; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_manifests
    ADD CONSTRAINT fk_rails_5525b9fd33 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: memory_proposals fk_rails_56739cb9bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_proposals
    ADD CONSTRAINT fk_rails_56739cb9bd FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: intercom_conversation_links fk_rails_57869e5e2b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_conversation_links
    ADD CONSTRAINT fk_rails_57869e5e2b FOREIGN KEY (workspace_id, conversation_id) REFERENCES public.conversations(workspace_id, id);


--
-- Name: knowledge_applicability_connections fk_rails_59220f7311; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicability_connections
    ADD CONSTRAINT fk_rails_59220f7311 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: intercom_sync_operations fk_rails_5a9c8244a7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_sync_operations
    ADD CONSTRAINT fk_rails_5a9c8244a7 FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: intercom_outbound_deliveries fk_rails_5b4607fe85; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT fk_rails_5b4607fe85 FOREIGN KEY (workspace_id, intercom_draft_id) REFERENCES public.intercom_drafts(workspace_id, id);


--
-- Name: knowledge_applicability_connections fk_rails_5c20820a29; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicability_connections
    ADD CONSTRAINT fk_rails_5c20820a29 FOREIGN KEY (workspace_id, knowledge_applicability_id) REFERENCES public.knowledge_applicabilities(workspace_id, id);


--
-- Name: intercom_part_attachments fk_rails_5c89cd5d50; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_attachments
    ADD CONSTRAINT fk_rails_5c89cd5d50 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: memory_correction_proposals fk_rails_5d140239d8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_correction_proposals
    ADD CONSTRAINT fk_rails_5d140239d8 FOREIGN KEY (workspace_id, memory_record_id) REFERENCES public.memory_records(workspace_id, id);


--
-- Name: knowledge_sources fk_rails_5d7fc285cc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sources
    ADD CONSTRAINT fk_rails_5d7fc285cc FOREIGN KEY (workspace_id, deleted_by_membership_id, deleted_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: source_identity_keys fk_rails_5d83b90732; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identity_keys
    ADD CONSTRAINT fk_rails_5d83b90732 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: identity_match_candidates fk_rails_5e06149d55; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates
    ADD CONSTRAINT fk_rails_5e06149d55 FOREIGN KEY (workspace_id, contact_id) REFERENCES public.contacts(workspace_id, id);


--
-- Name: case_notes fk_rails_5e366734ed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_notes
    ADD CONSTRAINT fk_rails_5e366734ed FOREIGN KEY (workspace_id, support_case_id) REFERENCES public.support_cases(workspace_id, id);


--
-- Name: knowledge_sources fk_rails_5ff9ba625d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sources
    ADD CONSTRAINT fk_rails_5ff9ba625d FOREIGN KEY (deleted_by_user_id) REFERENCES public.users(id);


--
-- Name: source_identities fk_rails_606ea51223; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identities
    ADD CONSTRAINT fk_rails_606ea51223 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: knowledge_applicability_connections fk_rails_60e8ac0fcd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicability_connections
    ADD CONSTRAINT fk_rails_60e8ac0fcd FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: governed_policy_publications fk_rails_60eeb27fea; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_publications
    ADD CONSTRAINT fk_rails_60eeb27fea FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: email_drafts fk_rails_6106ba6ad3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_rails_6106ba6ad3 FOREIGN KEY (workspace_id, updated_by_id) REFERENCES public.memberships(workspace_id, user_id);


--
-- Name: intercom_outbound_deliveries fk_rails_622677a4e2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT fk_rails_622677a4e2 FOREIGN KEY (workspace_id, intercom_connection_id, intercom_conversation_link_id, conversation_id) REFERENCES public.intercom_conversation_links(workspace_id, intercom_connection_id, id, conversation_id);


--
-- Name: sla_policies fk_rails_62486d6140; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT fk_rails_62486d6140 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: workspace_invitations fk_rails_627a78e220; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations
    ADD CONSTRAINT fk_rails_627a78e220 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: contacts fk_rails_62c8ec63c2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT fk_rails_62c8ec63c2 FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: knowledge_sync_passes fk_rails_64666e89d3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_passes
    ADD CONSTRAINT fk_rails_64666e89d3 FOREIGN KEY (workspace_id, notion_knowledge_connection_id) REFERENCES public.notion_knowledge_connections(workspace_id, id);


--
-- Name: contacts fk_rails_64c9be5440; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT fk_rails_64c9be5440 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: crew_templates fk_rails_665cdc9b64; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_templates
    ADD CONSTRAINT fk_rails_665cdc9b64 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: case_slas fk_rails_667d0037a5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_slas
    ADD CONSTRAINT fk_rails_667d0037a5 FOREIGN KEY (workspace_id, support_case_id) REFERENCES public.support_cases(workspace_id, id);


--
-- Name: health_scorecard_design_turns fk_rails_672c2dca10; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_design_turns
    ADD CONSTRAINT fk_rails_672c2dca10 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: identity_match_candidates fk_rails_687f013be7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates
    ADD CONSTRAINT fk_rails_687f013be7 FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: intercom_conversation_links fk_rails_690bd262a9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_conversation_links
    ADD CONSTRAINT fk_rails_690bd262a9 FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: outbound_email_deliveries fk_rails_691805fa36; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_691805fa36 FOREIGN KEY (workspace_id, email_draft_id) REFERENCES public.email_drafts(workspace_id, id);


--
-- Name: conversation_messages fk_rails_69e4535daa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages
    ADD CONSTRAINT fk_rails_69e4535daa FOREIGN KEY (workspace_id, author_contact_id) REFERENCES public.contacts(workspace_id, id);


--
-- Name: governed_policy_previews fk_rails_69fc9ef6d5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_previews
    ADD CONSTRAINT fk_rails_69fc9ef6d5 FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: agent_profile_versions fk_rails_6acb52efde; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profile_versions
    ADD CONSTRAINT fk_rails_6acb52efde FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: conversations fk_rails_6aeb936dee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT fk_rails_6aeb936dee FOREIGN KEY (workspace_id, contact_id) REFERENCES public.contacts(workspace_id, id);


--
-- Name: knowledge_applicabilities fk_rails_6ef60e00a3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicabilities
    ADD CONSTRAINT fk_rails_6ef60e00a3 FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: support_cases fk_rails_6f0c83db70; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_cases
    ADD CONSTRAINT fk_rails_6f0c83db70 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: knowledge_sync_observations fk_rails_6fc11be116; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_observations
    ADD CONSTRAINT fk_rails_6fc11be116 FOREIGN KEY (workspace_id, knowledge_source_id) REFERENCES public.knowledge_sources(workspace_id, id);


--
-- Name: outbound_email_deliveries fk_rails_70d4e66122; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_70d4e66122 FOREIGN KEY (workspace_id, shared_email_inbox_id, email_thread_id, conversation_id) REFERENCES public.email_threads(workspace_id, shared_email_inbox_id, id, conversation_id);


--
-- Name: public_web_extractions fk_rails_714893ef9b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_extractions
    ADD CONSTRAINT fk_rails_714893ef9b FOREIGN KEY (workspace_id, requested_by_membership_id, requested_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: governed_policy_proposals fk_rails_7166a75e9d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_proposals
    ADD CONSTRAINT fk_rails_7166a75e9d FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: memory_proposals fk_rails_71ef40da68; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_proposals
    ADD CONSTRAINT fk_rails_71ef40da68 FOREIGN KEY (workspace_id, reviewed_by_membership_id, reviewed_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: memory_tombstones fk_rails_720402ccee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_tombstones
    ADD CONSTRAINT fk_rails_720402ccee FOREIGN KEY (workspace_id, memory_record_id) REFERENCES public.memory_records(workspace_id, id);


--
-- Name: integration_user_connections fk_rails_723b7b724c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_user_connections
    ADD CONSTRAINT fk_rails_723b7b724c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: stored_attachments fk_rails_728f214969; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_attachments
    ADD CONSTRAINT fk_rails_728f214969 FOREIGN KEY (workspace_id, uploaded_by_membership_id, uploaded_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: account_merges fk_rails_73bbb32f1d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT fk_rails_73bbb32f1d FOREIGN KEY (merged_by_id) REFERENCES public.users(id);


--
-- Name: outbound_webhook_deliveries fk_rails_73f17d8db3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_webhook_deliveries
    ADD CONSTRAINT fk_rails_73f17d8db3 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: governed_policy_subjects fk_rails_746c054b19; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_subjects
    ADD CONSTRAINT fk_rails_746c054b19 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: crew_task_events fk_rails_74f0d28011; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_rails_74f0d28011 FOREIGN KEY (workspace_id, from_agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


--
-- Name: notifications fk_rails_7574b4405f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_7574b4405f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: workspace_invitations fk_rails_759aefbfd2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations
    ADD CONSTRAINT fk_rails_759aefbfd2 FOREIGN KEY (invited_by_id) REFERENCES public.users(id);


--
-- Name: execution_runs fk_rails_75a3606ffc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_rails_75a3606ffc FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: inbound_email_deliveries fk_rails_7716af08ad; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbound_email_deliveries
    ADD CONSTRAINT fk_rails_7716af08ad FOREIGN KEY (workspace_id, conversation_id) REFERENCES public.conversations(workspace_id, id);


--
-- Name: email_drafts fk_rails_77812b41a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_rails_77812b41a4 FOREIGN KEY (workspace_id, support_case_id, conversation_id) REFERENCES public.support_cases(workspace_id, id, conversation_id);


--
-- Name: knowledge_applicabilities fk_rails_78d36804bc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicabilities
    ADD CONSTRAINT fk_rails_78d36804bc FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: crew_artifacts fk_rails_7b0a9aadf7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts
    ADD CONSTRAINT fk_rails_7b0a9aadf7 FOREIGN KEY (workspace_id, crew_task_id) REFERENCES public.crew_tasks(workspace_id, id);


--
-- Name: crew_task_events fk_rails_7baa24c856; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_rails_7baa24c856 FOREIGN KEY (workspace_id, to_agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


--
-- Name: email_draft_attachments fk_rails_7bd5733974; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_draft_attachments
    ADD CONSTRAINT fk_rails_7bd5733974 FOREIGN KEY (workspace_id, email_draft_id) REFERENCES public.email_drafts(workspace_id, id);


--
-- Name: conversation_messages fk_rails_7c459f2c0a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages
    ADD CONSTRAINT fk_rails_7c459f2c0a FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: integration_oauth_attempts fk_rails_7cf3786d67; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_oauth_attempts
    ADD CONSTRAINT fk_rails_7cf3786d67 FOREIGN KEY (workspace_id, membership_id) REFERENCES public.memberships(workspace_id, id) ON DELETE CASCADE;


--
-- Name: intercom_tag_links fk_rails_7d6d79490f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_tag_links
    ADD CONSTRAINT fk_rails_7d6d79490f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: outbound_email_deliveries fk_rails_7da4fe3f02; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_7da4fe3f02 FOREIGN KEY (workspace_id, email_draft_id, email_thread_id, conversation_id) REFERENCES public.email_drafts(workspace_id, id, email_thread_id, conversation_id);


--
-- Name: source_identities fk_rails_7e80950554; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identities
    ADD CONSTRAINT fk_rails_7e80950554 FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: support_cases fk_rails_7f25fe210e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_cases
    ADD CONSTRAINT fk_rails_7f25fe210e FOREIGN KEY (workspace_id, assigned_membership_id) REFERENCES public.memberships(workspace_id, id);


--
-- Name: execution_memory_selections fk_rails_8362f08b7f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_memory_selections
    ADD CONSTRAINT fk_rails_8362f08b7f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: workspace_content_expiry_runs fk_rails_84778dd97f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_content_expiry_runs
    ADD CONSTRAINT fk_rails_84778dd97f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: workspace_tombstones fk_rails_863d31e253; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_tombstones
    ADD CONSTRAINT fk_rails_863d31e253 FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: execution_memory_selections fk_rails_87dc9e2226; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_memory_selections
    ADD CONSTRAINT fk_rails_87dc9e2226 FOREIGN KEY (workspace_id, execution_run_id) REFERENCES public.execution_runs(workspace_id, id) ON DELETE CASCADE;


--
-- Name: workspace_connectors fk_rails_885558a971; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_connectors
    ADD CONSTRAINT fk_rails_885558a971 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: agent_profiles fk_rails_89533dda30; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profiles
    ADD CONSTRAINT fk_rails_89533dda30 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: public_web_extractions fk_rails_8a71b0b31d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_extractions
    ADD CONSTRAINT fk_rails_8a71b0b31d FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: source_identity_keys fk_rails_8aa9bbdb8d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identity_keys
    ADD CONSTRAINT fk_rails_8aa9bbdb8d FOREIGN KEY (workspace_id, source_identity_id) REFERENCES public.source_identities(workspace_id, id);


--
-- Name: email_threads fk_rails_8b36ff71d2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_threads
    ADD CONSTRAINT fk_rails_8b36ff71d2 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: knowledge_sync_observations fk_rails_8b3b34e272; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_observations
    ADD CONSTRAINT fk_rails_8b3b34e272 FOREIGN KEY (workspace_id, last_seen_pass_id) REFERENCES public.knowledge_sync_passes(workspace_id, id);


--
-- Name: email_threads fk_rails_8d9401648e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_threads
    ADD CONSTRAINT fk_rails_8d9401648e FOREIGN KEY (workspace_id, shared_email_inbox_id) REFERENCES public.shared_email_inboxes(workspace_id, id);


--
-- Name: support_case_status_changes fk_rails_8ddc724e46; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_status_changes
    ADD CONSTRAINT fk_rails_8ddc724e46 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: support_case_taggings fk_rails_8f572d50d0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_taggings
    ADD CONSTRAINT fk_rails_8f572d50d0 FOREIGN KEY (workspace_id, tag_id) REFERENCES public.tags(workspace_id, id);


--
-- Name: crew_task_dependencies fk_rails_9030464aa5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_dependencies
    ADD CONSTRAINT fk_rails_9030464aa5 FOREIGN KEY (workspace_id, depends_on_task_id) REFERENCES public.crew_tasks(workspace_id, id);


--
-- Name: health_scorecard_versions fk_rails_91017e7908; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_versions
    ADD CONSTRAINT fk_rails_91017e7908 FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: contact_merges fk_rails_93b8e9788d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges
    ADD CONSTRAINT fk_rails_93b8e9788d FOREIGN KEY (unmerged_by_id) REFERENCES public.users(id);


--
-- Name: knowledge_sources fk_rails_957b648985; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sources
    ADD CONSTRAINT fk_rails_957b648985 FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: execution_runs fk_rails_96f8646048; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_rails_96f8646048 FOREIGN KEY (workspace_id, agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


--
-- Name: case_notes fk_rails_971560bd73; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_notes
    ADD CONSTRAINT fk_rails_971560bd73 FOREIGN KEY (author_id) REFERENCES public.users(id);


--
-- Name: public_web_searches fk_rails_986394303c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_searches
    ADD CONSTRAINT fk_rails_986394303c FOREIGN KEY (requested_by_user_id) REFERENCES public.users(id);


--
-- Name: public_web_search_results fk_rails_98800978bc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_search_results
    ADD CONSTRAINT fk_rails_98800978bc FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: memberships fk_rails_99326fb65d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_99326fb65d FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: intercom_backfill_batches fk_rails_9a094a74b7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_batches
    ADD CONSTRAINT fk_rails_9a094a74b7 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: intercom_drafts fk_rails_9b0efb02e5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_drafts
    ADD CONSTRAINT fk_rails_9b0efb02e5 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: intercom_backfill_reports fk_rails_9d9a7a4500; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_reports
    ADD CONSTRAINT fk_rails_9d9a7a4500 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: execution_runs fk_rails_9e0c3380dc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_runs
    ADD CONSTRAINT fk_rails_9e0c3380dc FOREIGN KEY (workspace_id, agent_profile_id, agent_profile_version_id) REFERENCES public.agent_profile_versions(workspace_id, agent_profile_id, id);


--
-- Name: conversation_message_attachments fk_rails_9f51c96886; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_message_attachments
    ADD CONSTRAINT fk_rails_9f51c96886 FOREIGN KEY (workspace_id, stored_attachment_id) REFERENCES public.stored_attachments(workspace_id, id);


--
-- Name: sla_escalation_tasks fk_rails_a0e954d864; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_escalation_tasks
    ADD CONSTRAINT fk_rails_a0e954d864 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: source_identities fk_rails_a2b33597e3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identities
    ADD CONSTRAINT fk_rails_a2b33597e3 FOREIGN KEY (resolved_by_id) REFERENCES public.users(id);


--
-- Name: memory_records fk_rails_a45336e54c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT fk_rails_a45336e54c FOREIGN KEY (workspace_id, contact_id) REFERENCES public.contacts(workspace_id, id);


--
-- Name: intercom_sync_operations fk_rails_a45d2aa602; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_sync_operations
    ADD CONSTRAINT fk_rails_a45d2aa602 FOREIGN KEY (workspace_id, membership_id, user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: crew_artifacts fk_rails_a5798990c4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts
    ADD CONSTRAINT fk_rails_a5798990c4 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: intercom_drafts fk_rails_a5ce61f9cd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_drafts
    ADD CONSTRAINT fk_rails_a5ce61f9cd FOREIGN KEY (workspace_id, support_case_id, conversation_id) REFERENCES public.support_cases(workspace_id, id, conversation_id);


--
-- Name: email_draft_attachments fk_rails_a6b8203129; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_draft_attachments
    ADD CONSTRAINT fk_rails_a6b8203129 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: account_risk_investigations fk_rails_a6c56dd60e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_risk_investigations
    ADD CONSTRAINT fk_rails_a6c56dd60e FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: outbound_email_deliveries fk_rails_a79332c57f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_a79332c57f FOREIGN KEY (actor_user_id) REFERENCES public.users(id);


--
-- Name: outbound_webhook_deliveries fk_rails_a922d62322; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_webhook_deliveries
    ADD CONSTRAINT fk_rails_a922d62322 FOREIGN KEY (notification_id) REFERENCES public.notifications(id);


--
-- Name: workspace_invitations fk_rails_aa0ff4982f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations
    ADD CONSTRAINT fk_rails_aa0ff4982f FOREIGN KEY (accepted_by_id) REFERENCES public.users(id);


--
-- Name: knowledge_applicabilities fk_rails_aad42f62d5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicabilities
    ADD CONSTRAINT fk_rails_aad42f62d5 FOREIGN KEY (workspace_id, knowledge_source_id) REFERENCES public.knowledge_sources(workspace_id, id);


--
-- Name: stored_attachments fk_rails_ab39bdb694; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_attachments
    ADD CONSTRAINT fk_rails_ab39bdb694 FOREIGN KEY (uploaded_by_user_id) REFERENCES public.users(id);


--
-- Name: intercom_outbound_deliveries fk_rails_ac200f3793; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT fk_rails_ac200f3793 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: identity_match_candidates fk_rails_ac435a87c8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates
    ADD CONSTRAINT fk_rails_ac435a87c8 FOREIGN KEY (workspace_id, source_identity_id) REFERENCES public.source_identities(workspace_id, id);


--
-- Name: knowledge_sources fk_rails_ad55aa375e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sources
    ADD CONSTRAINT fk_rails_ad55aa375e FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: runtime_installations fk_rails_ada199aa31; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runtime_installations
    ADD CONSTRAINT fk_rails_ada199aa31 FOREIGN KEY (workspace_id, approved_by_membership_id, approved_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: intercom_part_links fk_rails_ae8e54f273; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_links
    ADD CONSTRAINT fk_rails_ae8e54f273 FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: integration_oauth_attempts fk_rails_afca122577; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_oauth_attempts
    ADD CONSTRAINT fk_rails_afca122577 FOREIGN KEY (session_id) REFERENCES public.sessions(id) ON DELETE CASCADE;


--
-- Name: source_identities fk_rails_b04720ccd3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identities
    ADD CONSTRAINT fk_rails_b04720ccd3 FOREIGN KEY (workspace_id, contact_id) REFERENCES public.contacts(workspace_id, id);


--
-- Name: case_notes fk_rails_b1575b0540; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_notes
    ADD CONSTRAINT fk_rails_b1575b0540 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: governed_policy_previews fk_rails_b27dc165eb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.governed_policy_previews
    ADD CONSTRAINT fk_rails_b27dc165eb FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: resolution_contract_versions fk_rails_b32fecdc41; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_contract_versions
    ADD CONSTRAINT fk_rails_b32fecdc41 FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: identity_match_candidates fk_rails_b43f253bd6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates
    ADD CONSTRAINT fk_rails_b43f253bd6 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: conversations fk_rails_b44b6eb8c4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT fk_rails_b44b6eb8c4 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: intercom_sync_operations fk_rails_b4af67e2ba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_sync_operations
    ADD CONSTRAINT fk_rails_b4af67e2ba FOREIGN KEY (workspace_id, intercom_connection_id, intercom_conversation_link_id) REFERENCES public.intercom_conversation_links(workspace_id, intercom_connection_id, id);


--
-- Name: outbound_email_deliveries fk_rails_b701b64a91; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_b701b64a91 FOREIGN KEY (workspace_id, actor_membership_id, actor_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: knowledge_sync_passes fk_rails_b71b5f79a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_passes
    ADD CONSTRAINT fk_rails_b71b5f79a4 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: email_message_links fk_rails_b76245f589; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_links
    ADD CONSTRAINT fk_rails_b76245f589 FOREIGN KEY (workspace_id, shared_email_inbox_id, email_thread_id, conversation_id) REFERENCES public.email_threads(workspace_id, shared_email_inbox_id, id, conversation_id);


--
-- Name: personal_provider_accounts fk_rails_b8dd135c1c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_provider_accounts
    ADD CONSTRAINT fk_rails_b8dd135c1c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: intercom_drafts fk_rails_b8e2a27ef3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_drafts
    ADD CONSTRAINT fk_rails_b8e2a27ef3 FOREIGN KEY (workspace_id, updated_by_id) REFERENCES public.memberships(workspace_id, user_id);


--
-- Name: email_drafts fk_rails_b945d268da; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_rails_b945d268da FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: intercom_backfill_runs fk_rails_baab70cb97; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_runs
    ADD CONSTRAINT fk_rails_baab70cb97 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: accounts fk_rails_bac5365c2c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT fk_rails_bac5365c2c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: crew_artifacts fk_rails_bb2eb7b83b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_artifacts
    ADD CONSTRAINT fk_rails_bb2eb7b83b FOREIGN KEY (workspace_id, execution_run_id, crew_task_id) REFERENCES public.execution_runs(workspace_id, id, crew_task_id);


--
-- Name: memory_tombstones fk_rails_bbc0186171; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_tombstones
    ADD CONSTRAINT fk_rails_bbc0186171 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: knowledge_sources fk_rails_bcd8a59540; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sources
    ADD CONSTRAINT fk_rails_bcd8a59540 FOREIGN KEY (workspace_id, notion_knowledge_connection_id) REFERENCES public.notion_knowledge_connections(workspace_id, id);


--
-- Name: account_health_inputs fk_rails_bd914d14d2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_inputs
    ADD CONSTRAINT fk_rails_bd914d14d2 FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: public_web_searches fk_rails_bfba850d20; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_searches
    ADD CONSTRAINT fk_rails_bfba850d20 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: support_case_status_changes fk_rails_c0b65ffdac; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_status_changes
    ADD CONSTRAINT fk_rails_c0b65ffdac FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: support_case_status_changes fk_rails_c15e982c02; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_status_changes
    ADD CONSTRAINT fk_rails_c15e982c02 FOREIGN KEY (workspace_id, support_case_id) REFERENCES public.support_cases(workspace_id, id);


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: execution_memory_selections fk_rails_c41ed85868; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_memory_selections
    ADD CONSTRAINT fk_rails_c41ed85868 FOREIGN KEY (workspace_id, memory_record_id) REFERENCES public.memory_records(workspace_id, id);


--
-- Name: intercom_conversation_links fk_rails_c5d76feb3f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_conversation_links
    ADD CONSTRAINT fk_rails_c5d76feb3f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: integration_oauth_attempts fk_rails_c5e0463307; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_oauth_attempts
    ADD CONSTRAINT fk_rails_c5e0463307 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: account_health_inputs fk_rails_c62df8f1a3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_inputs
    ADD CONSTRAINT fk_rails_c62df8f1a3 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: health_scorecard_design_turns fk_rails_c6843b5d52; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_design_turns
    ADD CONSTRAINT fk_rails_c6843b5d52 FOREIGN KEY (workspace_id, health_scorecard_id) REFERENCES public.health_scorecards(workspace_id, id);


--
-- Name: notion_knowledge_connections fk_rails_c6a658f24f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notion_knowledge_connections
    ADD CONSTRAINT fk_rails_c6a658f24f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: public_web_extractions fk_rails_c6f2785e1f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_extractions
    ADD CONSTRAINT fk_rails_c6f2785e1f FOREIGN KEY (workspace_id, public_web_search_result_id) REFERENCES public.public_web_search_results(workspace_id, id) ON DELETE CASCADE;


--
-- Name: shared_email_inboxes fk_rails_c70ce652a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shared_email_inboxes
    ADD CONSTRAINT fk_rails_c70ce652a0 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: email_drafts fk_rails_c7a7ee21ef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_rails_c7a7ee21ef FOREIGN KEY (updated_by_id) REFERENCES public.users(id);


--
-- Name: memory_index_entries fk_rails_c8546818c4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_index_entries
    ADD CONSTRAINT fk_rails_c8546818c4 FOREIGN KEY (workspace_id, memory_record_id) REFERENCES public.memory_records(workspace_id, id) ON DELETE CASCADE;


--
-- Name: account_health_assessments fk_rails_c87bc4b570; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_assessments
    ADD CONSTRAINT fk_rails_c87bc4b570 FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: usage_rate_settings fk_rails_c8855db661; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_rate_settings
    ADD CONSTRAINT fk_rails_c8855db661 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: intercom_backfill_exceptions fk_rails_c8d2251440; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_backfill_exceptions
    ADD CONSTRAINT fk_rails_c8d2251440 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: outbound_email_deliveries fk_rails_c98bb924c2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_c98bb924c2 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: knowledge_source_versions fk_rails_ca0065d632; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_versions
    ADD CONSTRAINT fk_rails_ca0065d632 FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: customer_success_interventions fk_rails_ca35eeca1f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_interventions
    ADD CONSTRAINT fk_rails_ca35eeca1f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: knowledge_source_versions fk_rails_ca93bc035d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_versions
    ADD CONSTRAINT fk_rails_ca93bc035d FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: crew_task_events fk_rails_cae149d86b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_rails_cae149d86b FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: support_case_taggings fk_rails_ccfa3c71c0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_case_taggings
    ADD CONSTRAINT fk_rails_ccfa3c71c0 FOREIGN KEY (workspace_id, source_intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: conversation_messages fk_rails_cd0fa9de6c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages
    ADD CONSTRAINT fk_rails_cd0fa9de6c FOREIGN KEY (author_user_id) REFERENCES public.users(id);


--
-- Name: crew_tasks fk_rails_cd8a5efbb3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_rails_cd8a5efbb3 FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: audit_events fk_rails_cdb00c0cbd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_cdb00c0cbd FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: crew_tasks fk_rails_d14d5b5554; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_rails_d14d5b5554 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: inbound_email_deliveries fk_rails_d22cd212fa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbound_email_deliveries
    ADD CONSTRAINT fk_rails_d22cd212fa FOREIGN KEY (workspace_id, shared_email_inbox_id) REFERENCES public.shared_email_inboxes(workspace_id, id);


--
-- Name: inbound_email_deliveries fk_rails_d25c9cc250; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbound_email_deliveries
    ADD CONSTRAINT fk_rails_d25c9cc250 FOREIGN KEY (workspace_id, conversation_id, conversation_message_id) REFERENCES public.conversation_messages(workspace_id, conversation_id, id);


--
-- Name: outbound_webhook_deliveries fk_rails_d25dea0cdd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_webhook_deliveries
    ADD CONSTRAINT fk_rails_d25dea0cdd FOREIGN KEY (outbound_webhook_endpoint_id) REFERENCES public.outbound_webhook_endpoints(id);


--
-- Name: integration_user_connections fk_rails_d296247610; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_user_connections
    ADD CONSTRAINT fk_rails_d296247610 FOREIGN KEY (workspace_id, workspace_connector_id) REFERENCES public.workspace_connectors(workspace_id, id) ON DELETE CASCADE;


--
-- Name: usage_cost_snapshots fk_rails_d396824a0c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_cost_snapshots
    ADD CONSTRAINT fk_rails_d396824a0c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: knowledge_source_versions fk_rails_d40427c568; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_versions
    ADD CONSTRAINT fk_rails_d40427c568 FOREIGN KEY (workspace_id, stored_attachment_id) REFERENCES public.stored_attachments(workspace_id, id);


--
-- Name: knowledge_applicability_products fk_rails_d46c3a828d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_applicability_products
    ADD CONSTRAINT fk_rails_d46c3a828d FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: public_web_extractions fk_rails_d470a92618; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_extractions
    ADD CONSTRAINT fk_rails_d470a92618 FOREIGN KEY (requested_by_user_id) REFERENCES public.users(id);


--
-- Name: memory_proposals fk_rails_d54615fe35; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_proposals
    ADD CONSTRAINT fk_rails_d54615fe35 FOREIGN KEY (workspace_id, source_agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


--
-- Name: intercom_drafts fk_rails_d6dabca820; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_drafts
    ADD CONSTRAINT fk_rails_d6dabca820 FOREIGN KEY (workspace_id, intercom_conversation_link_id, conversation_id) REFERENCES public.intercom_conversation_links(workspace_id, id, conversation_id);


--
-- Name: usage_rate_versions fk_rails_dbc87c3d7f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_rate_versions
    ADD CONSTRAINT fk_rails_dbc87c3d7f FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: audit_events fk_rails_dd1f3a471a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_dd1f3a471a FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: email_message_links fk_rails_de7eae5c16; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_links
    ADD CONSTRAINT fk_rails_de7eae5c16 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: customer_success_intervention_outcome_reviews fk_rails_df4b274cee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_success_intervention_outcome_reviews
    ADD CONSTRAINT fk_rails_df4b274cee FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: health_scorecard_backtests fk_rails_e06550e89d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_backtests
    ADD CONSTRAINT fk_rails_e06550e89d FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: knowledge_sync_passes fk_rails_e0aac5a6ff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_passes
    ADD CONSTRAINT fk_rails_e0aac5a6ff FOREIGN KEY (workspace_id, intercom_connection_id) REFERENCES public.intercom_connections(workspace_id, id);


--
-- Name: notifications fk_rails_e14bd42d63; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_e14bd42d63 FOREIGN KEY (recipient_membership_id) REFERENCES public.memberships(id);


--
-- Name: crew_tasks fk_rails_e3cb7df8ab; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_rails_e3cb7df8ab FOREIGN KEY (owner_user_id) REFERENCES public.users(id);


--
-- Name: sla_policies fk_rails_e77dea60a1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT fk_rails_e77dea60a1 FOREIGN KEY (workspace_id, service_calendar_id) REFERENCES public.service_calendars(workspace_id, id);


--
-- Name: memberships fk_rails_e7b442f67c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_e7b442f67c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: workspace_tombstones fk_rails_e8558236cd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_tombstones
    ADD CONSTRAINT fk_rails_e8558236cd FOREIGN KEY (deleted_by_id) REFERENCES public.users(id);


--
-- Name: memory_proposals fk_rails_ea109a1c9b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_proposals
    ADD CONSTRAINT fk_rails_ea109a1c9b FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: email_threads fk_rails_ea636c8d06; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_threads
    ADD CONSTRAINT fk_rails_ea636c8d06 FOREIGN KEY (workspace_id, conversation_id) REFERENCES public.conversations(workspace_id, id);


--
-- Name: public_web_searches fk_rails_ea64d80603; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.public_web_searches
    ADD CONSTRAINT fk_rails_ea64d80603 FOREIGN KEY (workspace_id, requested_by_membership_id, requested_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: intercom_part_links fk_rails_eb6f32a090; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_links
    ADD CONSTRAINT fk_rails_eb6f32a090 FOREIGN KEY (workspace_id, conversation_id, conversation_message_id) REFERENCES public.conversation_messages(workspace_id, conversation_id, id);


--
-- Name: intercom_tag_links fk_rails_ed77a1dddb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_tag_links
    ADD CONSTRAINT fk_rails_ed77a1dddb FOREIGN KEY (workspace_id, tag_id) REFERENCES public.tags(workspace_id, id);


--
-- Name: email_message_links fk_rails_edb13a72d9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_links
    ADD CONSTRAINT fk_rails_edb13a72d9 FOREIGN KEY (workspace_id, conversation_id, conversation_message_id) REFERENCES public.conversation_messages(workspace_id, conversation_id, id);


--
-- Name: intercom_webhook_deliveries fk_rails_ef28c0b16b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_webhook_deliveries
    ADD CONSTRAINT fk_rails_ef28c0b16b FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: usage_rate_versions fk_rails_f077dd8e71; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_rate_versions
    ADD CONSTRAINT fk_rails_f077dd8e71 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: account_risk_investigations fk_rails_f07d09c602; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_risk_investigations
    ADD CONSTRAINT fk_rails_f07d09c602 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: outbound_email_delivery_attachments fk_rails_f20f8e12d5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_delivery_attachments
    ADD CONSTRAINT fk_rails_f20f8e12d5 FOREIGN KEY (workspace_id, outbound_email_delivery_id) REFERENCES public.outbound_email_deliveries(workspace_id, id);


--
-- Name: resolution_contract_families fk_rails_f24e481302; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_contract_families
    ADD CONSTRAINT fk_rails_f24e481302 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: conversation_message_attachments fk_rails_f28ac313d8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_message_attachments
    ADD CONSTRAINT fk_rails_f28ac313d8 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: outbound_email_deliveries fk_rails_f29673b049; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_f29673b049 FOREIGN KEY (workspace_id, conversation_id, conversation_message_id) REFERENCES public.conversation_messages(workspace_id, conversation_id, id);


--
-- Name: integration_user_connections fk_rails_f5152a70b4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_user_connections
    ADD CONSTRAINT fk_rails_f5152a70b4 FOREIGN KEY (workspace_id, membership_id) REFERENCES public.memberships(workspace_id, id) ON DELETE CASCADE;


--
-- Name: notion_knowledge_connections fk_rails_f62cc8af4b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notion_knowledge_connections
    ADD CONSTRAINT fk_rails_f62cc8af4b FOREIGN KEY (workspace_id, workspace_connector_id) REFERENCES public.workspace_connectors(workspace_id, id);


--
-- Name: intercom_part_links fk_rails_f74cdd9944; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_part_links
    ADD CONSTRAINT fk_rails_f74cdd9944 FOREIGN KEY (workspace_id, intercom_connection_id, intercom_conversation_link_id, conversation_id) REFERENCES public.intercom_conversation_links(workspace_id, intercom_connection_id, id, conversation_id);


--
-- Name: health_scorecard_backtests fk_rails_f7564a3040; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scorecard_backtests
    ADD CONSTRAINT fk_rails_f7564a3040 FOREIGN KEY (workspace_id, membership_id, user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: oidc_identities fk_rails_f976bdec82; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_identities
    ADD CONSTRAINT fk_rails_f976bdec82 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: intercom_outbound_deliveries fk_rails_f98c838305; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercom_outbound_deliveries
    ADD CONSTRAINT fk_rails_f98c838305 FOREIGN KEY (workspace_id, intercom_draft_id, intercom_conversation_link_id, conversation_id) REFERENCES public.intercom_drafts(workspace_id, id, intercom_conversation_link_id, conversation_id);


--
-- Name: outbound_email_delivery_attachments fk_rails_f9dc4462b2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_delivery_attachments
    ADD CONSTRAINT fk_rails_f9dc4462b2 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: account_risk_investigations fk_rails_fa70abcfa9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_risk_investigations
    ADD CONSTRAINT fk_rails_fa70abcfa9 FOREIGN KEY (workspace_id, crew_task_id) REFERENCES public.crew_tasks(workspace_id, id);


--
-- Name: email_message_links fk_rails_fad997ec9c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_links
    ADD CONSTRAINT fk_rails_fad997ec9c FOREIGN KEY (workspace_id, shared_email_inbox_id) REFERENCES public.shared_email_inboxes(workspace_id, id);


--
-- Name: runtime_installations fk_rails_fbdd11bced; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runtime_installations
    ADD CONSTRAINT fk_rails_fbdd11bced FOREIGN KEY (workspace_id, personal_provider_account_id) REFERENCES public.personal_provider_accounts(workspace_id, id);


--
-- Name: resolution_contract_versions fk_rails_fcad053a4a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_contract_versions
    ADD CONSTRAINT fk_rails_fcad053a4a FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: contact_merges fk_rails_fd7d089b62; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges
    ADD CONSTRAINT fk_rails_fd7d089b62 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: email_draft_attachments fk_rails_fefc5eb6d1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_draft_attachments
    ADD CONSTRAINT fk_rails_fefc5eb6d1 FOREIGN KEY (workspace_id, stored_attachment_id) REFERENCES public.stored_attachments(workspace_id, id);


--
-- Name: agent_profile_versions fk_rails_ff1fbc8992; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profile_versions
    ADD CONSTRAINT fk_rails_ff1fbc8992 FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: account_health_assessments fk_rails_ff4368efa6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_health_assessments
    ADD CONSTRAINT fk_rails_ff4368efa6 FOREIGN KEY (workspace_id, health_scorecard_version_id) REFERENCES public.health_scorecard_versions(workspace_id, id);


--
-- Name: resolution_contract_families fk_resolution_contract_families_current_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_contract_families
    ADD CONSTRAINT fk_resolution_contract_families_current_version FOREIGN KEY (workspace_id, id, current_version_id) REFERENCES public.resolution_contract_versions(workspace_id, resolution_contract_family_id, id);


--
-- Name: resolution_contract_versions fk_resolution_contract_versions_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_contract_versions
    ADD CONSTRAINT fk_resolution_contract_versions_actor FOREIGN KEY (workspace_id, created_by_membership_id, created_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: resolution_contract_versions fk_resolution_contract_versions_family; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_contract_versions
    ADD CONSTRAINT fk_resolution_contract_versions_family FOREIGN KEY (workspace_id, resolution_contract_family_id) REFERENCES public.resolution_contract_families(workspace_id, id);


--
-- Name: crew_task_events fk_task_events_from_contract; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_task_events_from_contract FOREIGN KEY (workspace_id, from_resolution_contract_version_id) REFERENCES public.resolution_contract_versions(workspace_id, id);


--
-- Name: crew_task_events fk_task_events_from_exact_policy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_task_events_from_exact_policy FOREIGN KEY (workspace_id, from_governed_policy_publication_id, from_resolution_contract_version_id, from_agent_profile_version_id) REFERENCES public.governed_policy_publications(workspace_id, id, resolution_contract_version_id, agent_profile_version_id);


--
-- Name: crew_task_events fk_task_events_from_policy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_task_events_from_policy FOREIGN KEY (workspace_id, from_governed_policy_publication_id) REFERENCES public.governed_policy_publications(workspace_id, id);


--
-- Name: crew_task_events fk_task_events_to_contract; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_task_events_to_contract FOREIGN KEY (workspace_id, to_resolution_contract_version_id) REFERENCES public.resolution_contract_versions(workspace_id, id);


--
-- Name: crew_task_events fk_task_events_to_exact_policy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_task_events_to_exact_policy FOREIGN KEY (workspace_id, to_governed_policy_publication_id, to_resolution_contract_version_id, to_agent_profile_version_id) REFERENCES public.governed_policy_publications(workspace_id, id, resolution_contract_version_id, agent_profile_version_id);


--
-- Name: crew_task_events fk_task_events_to_policy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_task_events_to_policy FOREIGN KEY (workspace_id, to_governed_policy_publication_id) REFERENCES public.governed_policy_publications(workspace_id, id);


--
-- Name: usage_cost_snapshots fk_usage_cost_snapshots_rate; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_cost_snapshots
    ADD CONSTRAINT fk_usage_cost_snapshots_rate FOREIGN KEY (workspace_id, applied_usage_rate_version_id) REFERENCES public.usage_rate_versions(workspace_id, id);


--
-- Name: usage_cost_snapshots fk_usage_cost_snapshots_run; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_cost_snapshots
    ADD CONSTRAINT fk_usage_cost_snapshots_run FOREIGN KEY (workspace_id, execution_run_id) REFERENCES public.execution_runs(workspace_id, id);


--
-- Name: usage_cost_snapshots fk_usage_cost_snapshots_search; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_cost_snapshots
    ADD CONSTRAINT fk_usage_cost_snapshots_search FOREIGN KEY (workspace_id, public_web_search_id) REFERENCES public.public_web_searches(workspace_id, id);


--
-- Name: usage_rate_settings fk_usage_rate_settings_current_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_rate_settings
    ADD CONSTRAINT fk_usage_rate_settings_current_version FOREIGN KEY (workspace_id, id, current_version_id) REFERENCES public.usage_rate_versions(workspace_id, usage_rate_setting_id, id);


--
-- Name: usage_rate_versions fk_usage_rate_versions_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_rate_versions
    ADD CONSTRAINT fk_usage_rate_versions_actor FOREIGN KEY (workspace_id, created_by_membership_id, created_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: usage_rate_versions fk_usage_rate_versions_setting; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_rate_versions
    ADD CONSTRAINT fk_usage_rate_versions_setting FOREIGN KEY (workspace_id, usage_rate_setting_id) REFERENCES public.usage_rate_settings(workspace_id, id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260906060000'),
('20260906050000'),
('20260906041000'),
('20260906040000'),
('20260906020000'),
('20260906010000'),
('20260906000000'),
('20260901020000'),
('20260901010000'),
('20260831143000'),
('20260831121000'),
('20260831120000'),
('20260829000000'),
('20260828233000'),
('20260828230000'),
('20260828220000'),
('20260828210000'),
('20260827220000'),
('20260827210000'),
('20260827202000'),
('20260827201000'),
('20260827200000'),
('20260827193000'),
('20260827190000'),
('20260826140000'),
('20260826123000'),
('20260826120000'),
('20260825220000'),
('20260824230700'),
('20260824230600'),
('20260824230500'),
('20260824230400'),
('20260824230300'),
('20260824230100'),
('20260824230000'),
('20260824220000'),
('20260824210000'),
('20260824200000'),
('20260824190000'),
('20260824180000'),
('20260824170000'),
('20260824160000'),
('20260824150000'),
('20260824140000'),
('20260824130000'),
('20260824120000'),
('20260824110000'),
('20260824090000'),
('20260824081944'),
('20260824040011'),
('20260824040010'),
('20260824040009'),
('20260824040008'),
('20260824040007'),
('20260824040006'),
('20260824040005'),
('20260823200308'),
('20260823200307'),
('20260823200306'),
('20260823200305'),
('20260823200304'),
('20260823200303'),
('20260823200302'),
('20260823200301'),
('20260823200300'),
('20260823200259'),
('20260823200258'),
('20260823200257'),
('20260823195260'),
('20260823195259'),
('20260823195258'),
('20260823195257'),
('20260823193334');
