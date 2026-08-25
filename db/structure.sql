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
DECLARE
  role text;
  maximum_tools jsonb;
BEGIN
  SELECT role_key INTO role FROM agent_profiles
  WHERE id = NEW.agent_profile_id AND workspace_id = NEW.workspace_id
  FOR UPDATE;
  maximum_tools := CASE role
    WHEN 'support_coordinator' THEN '["conversation_read", "case_read"]'::jsonb
    WHEN 'support_investigator' THEN '["conversation_read", "case_read", "knowledge_search", "public_web_search"]'::jsonb
    WHEN 'resolution_drafter' THEN '["conversation_read", "case_read", "knowledge_search", "draft_propose"]'::jsonb
    WHEN 'support_reviewer' THEN '["conversation_read", "case_read", "knowledge_search", "review_record"]'::jsonb
    WHEN 'account_analyst' THEN '["account_read", "conversation_read"]'::jsonb
    WHEN 'risk_investigator' THEN '["account_read", "conversation_read", "knowledge_search", "public_web_search"]'::jsonb
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


SET default_tablespace = '';

SET default_table_access_method = heap;

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
    CONSTRAINT agent_profile_versions_actor CHECK ((((created_by_membership_id IS NULL) AND (created_by_user_id IS NULL)) OR ((created_by_membership_id IS NOT NULL) AND (created_by_user_id IS NOT NULL)))),
    CONSTRAINT agent_profile_versions_budget CHECK (((timeout_seconds >= 30) AND (timeout_seconds <= 900) AND ((max_steps >= 1) AND (max_steps <= 20)) AND ((max_tool_calls >= 0) AND (max_tool_calls <= 50)))),
    CONSTRAINT agent_profile_versions_instructions CHECK (((octet_length(instructions) >= 1) AND (octet_length(instructions) <= 8000))),
    CONSTRAINT agent_profile_versions_number CHECK ((version_number > 0)),
    CONSTRAINT agent_profile_versions_review CHECK (((review_policy)::text = ANY (ARRAY[('required'::character varying)::text, ('on_policy_flag'::character varying)::text]))),
    CONSTRAINT agent_profile_versions_runtime CHECK ((((runtime_profile_key)::text = ANY (ARRAY[('workspace_default'::character varying)::text, ('thorough'::character varying)::text, ('fast'::character varying)::text])) AND (jsonb_typeof(fallback_profile_keys) = 'array'::text) AND (jsonb_array_length(fallback_profile_keys) <= 2) AND (fallback_profile_keys <@ '["workspace_default", "thorough", "fast"]'::jsonb))),
    CONSTRAINT agent_profile_versions_tools CHECK (((jsonb_typeof(allowed_tools) = 'array'::text) AND (jsonb_array_length(allowed_tools) <= 8) AND (allowed_tools <@ '["conversation_read", "case_read", "account_read", "knowledge_search", "public_web_search", "draft_propose", "note_propose", "review_record"]'::jsonb)))
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
    CONSTRAINT crew_task_events_actor CHECK ((((actor_membership_id IS NULL) AND (actor_user_id IS NULL)) OR ((actor_membership_id IS NOT NULL) AND (actor_user_id IS NOT NULL)))),
    CONSTRAINT crew_task_events_body CHECK (((body IS NULL) OR ((octet_length(body) >= 1) AND (octet_length(body) <= 20000)))),
    CONSTRAINT crew_task_events_evidence_kind CHECK (((evidence_kind IS NULL) OR ((evidence_kind)::text = ANY (ARRAY[('conversation'::character varying)::text, ('case'::character varying)::text, ('account'::character varying)::text, ('knowledge'::character varying)::text, ('public_web'::character varying)::text, ('other'::character varying)::text])))),
    CONSTRAINT crew_task_events_evidence_locator CHECK (((evidence_locator IS NULL) OR ((octet_length((evidence_locator)::text) >= 1) AND (octet_length((evidence_locator)::text) <= 2000)))),
    CONSTRAINT crew_task_events_kind CHECK (((event_kind)::text = ANY (ARRAY[('created'::character varying)::text, ('status_changed'::character varying)::text, ('handoff'::character varying)::text, ('comment'::character varying)::text, ('evidence_added'::character varying)::text, ('review_requested'::character varying)::text, ('review_resolved'::character varying)::text, ('outcome_recorded'::character varying)::text]))),
    CONSTRAINT crew_task_events_outcome_kind CHECK (((outcome_kind IS NULL) OR ((outcome_kind)::text = ANY (ARRAY[('completed'::character varying)::text, ('failed'::character varying)::text, ('canceled'::character varying)::text])))),
    CONSTRAINT crew_task_events_review_outcome CHECK (((review_outcome IS NULL) OR ((review_outcome)::text = ANY (ARRAY[('approved'::character varying)::text, ('changes_requested'::character varying)::text])))),
    CONSTRAINT crew_task_events_sequence CHECK ((sequence_number > 0)),
    CONSTRAINT crew_task_events_source CHECK (((source)::text = ANY (ARRAY[('web'::character varying)::text, ('task'::character varying)::text, ('runner'::character varying)::text, ('system'::character varying)::text])))
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
    CONSTRAINT crew_tasks_content CHECK (((octet_length((title)::text) >= 1) AND (octet_length((title)::text) <= 200) AND ((octet_length(input_context) >= 1) AND (octet_length(input_context) <= 8000)) AND ((octet_length(expected_output) >= 1) AND (octet_length(expected_output) <= 8000)))),
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
    CONSTRAINT email_drafts_body_size CHECK ((octet_length(body) <= 1048576)),
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
    CONSTRAINT knowledge_source_versions_actor CHECK ((((created_by_membership_id IS NULL) AND (created_by_user_id IS NULL)) OR ((created_by_membership_id IS NOT NULL) AND (created_by_user_id IS NOT NULL)))),
    CONSTRAINT knowledge_source_versions_content_size CHECK (((octet_length(content) >= 1) AND (octet_length(content) <= 1048576))),
    CONSTRAINT knowledge_source_versions_number CHECK ((version_number > 0)),
    CONSTRAINT knowledge_source_versions_sha256 CHECK (((content_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT knowledge_source_versions_url_length CHECK (((retrieved_from_url IS NULL) OR (((retrieved_from_url)::text ~ '^https://'::text) AND (length((retrieved_from_url)::text) <= 2048))))
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
    CONSTRAINT knowledge_sources_deletion CHECK ((((deleted_at IS NULL) AND (deleted_by_membership_id IS NULL) AND (deleted_by_user_id IS NULL)) OR ((deleted_at IS NOT NULL) AND (deleted_by_membership_id IS NOT NULL) AND (deleted_by_user_id IS NOT NULL)))),
    CONSTRAINT knowledge_sources_identity CHECK ((((title)::text <> ''::text) AND (length((title)::text) <= 200) AND ((canonical_url IS NULL) OR (length((canonical_url)::text) <= 2048)) AND ((external_id IS NULL) OR (((external_id)::text <> ''::text) AND (length((external_id)::text) <= 500))))),
    CONSTRAINT knowledge_sources_key CHECK (((source_key)::text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'::text)),
    CONSTRAINT knowledge_sources_kind CHECK (((source_kind)::text = ANY (ARRAY[('manual'::character varying)::text, ('url'::character varying)::text, ('upload'::character varying)::text, ('intercom_help_center'::character varying)::text]))),
    CONSTRAINT knowledge_sources_locator CHECK (((((source_kind)::text = 'url'::text) AND ((canonical_url)::text ~ '^https://'::text) AND (external_id IS NULL)) OR (((source_kind)::text = 'intercom_help_center'::text) AND (external_id IS NOT NULL) AND (canonical_url IS NULL)) OR (((source_kind)::text = ANY (ARRAY[('manual'::character varying)::text, ('upload'::character varying)::text])) AND (canonical_url IS NULL) AND (external_id IS NULL))))
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
    CONSTRAINT outbound_email_deliveries_body_size CHECK ((octet_length(body) <= 1048576)),
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
    CONSTRAINT sessions_authentication_method CHECK (((authentication_method)::text = ANY (ARRAY[('local'::character varying)::text, ('break_glass'::character varying)::text])))
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
    CONSTRAINT stored_attachments_actor CHECK (((((source)::text = 'inbound_email'::text) AND (uploaded_by_membership_id IS NULL) AND (uploaded_by_user_id IS NULL)) OR (((source)::text = 'user_upload'::text) AND (uploaded_by_membership_id IS NOT NULL) AND (uploaded_by_user_id IS NOT NULL)))),
    CONSTRAINT stored_attachments_scan_state CHECK (((scan_result_code IS NOT NULL) AND ((scan_result_code)::text <> ''::text) AND ((((scan_status)::text = 'quarantined'::text) AND (scanned_at IS NULL)) OR (((scan_status)::text = ANY (ARRAY[('available'::character varying)::text, ('rejected'::character varying)::text])) AND (scanned_at IS NOT NULL))))),
    CONSTRAINT stored_attachments_scan_status CHECK (((scan_status)::text = ANY (ARRAY[('quarantined'::character varying)::text, ('available'::character varying)::text, ('rejected'::character varying)::text]))),
    CONSTRAINT stored_attachments_sha256 CHECK (((content_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT stored_attachments_size CHECK (((byte_size >= 1) AND (byte_size <= 5242880))),
    CONSTRAINT stored_attachments_source CHECK (((source)::text = ANY (ARRAY[('inbound_email'::character varying)::text, ('user_upload'::character varying)::text])))
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
    updated_at timestamp(6) without time zone NOT NULL
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
-- Name: workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspaces (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    runner_key uuid DEFAULT gen_random_uuid() NOT NULL
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
-- Name: account_merges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges ALTER COLUMN id SET DEFAULT nextval('public.account_merges_id_seq'::regclass);


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
-- Name: knowledge_source_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_versions ALTER COLUMN id SET DEFAULT nextval('public.knowledge_source_versions_id_seq'::regclass);


--
-- Name: knowledge_sources id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sources ALTER COLUMN id SET DEFAULT nextval('public.knowledge_sources_id_seq'::regclass);


--
-- Name: memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships ALTER COLUMN id SET DEFAULT nextval('public.memberships_id_seq'::regclass);


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
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: workspace_invitations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations ALTER COLUMN id SET DEFAULT nextval('public.workspace_invitations_id_seq'::regclass);


--
-- Name: workspaces id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces ALTER COLUMN id SET DEFAULT nextval('public.workspaces_id_seq'::regclass);


--
-- Name: account_merges account_merges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT account_merges_pkey PRIMARY KEY (id);


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
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);


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
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: workspace_invitations workspace_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations
    ADD CONSTRAINT workspace_invitations_pkey PRIMARY KEY (id);


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
-- Name: index_crew_tasks_on_account_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_tasks_on_account_and_status ON public.crew_tasks USING btree (workspace_id, account_id, status);


--
-- Name: index_crew_tasks_on_case_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_crew_tasks_on_case_and_status ON public.crew_tasks USING btree (workspace_id, support_case_id, status);


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
-- Name: index_current_source_identity_keys; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_current_source_identity_keys ON public.source_identity_keys USING btree (source_identity_id, kind, normalized_value) WHERE (retired_at IS NULL);


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

CREATE UNIQUE INDEX index_knowledge_sources_on_workspace_kind_external ON public.knowledge_sources USING btree (workspace_id, source_kind, external_id) WHERE (external_id IS NOT NULL);


--
-- Name: index_knowledge_sources_on_workspace_kind_url; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_sources_on_workspace_kind_url ON public.knowledge_sources USING btree (workspace_id, source_kind, canonical_url) WHERE (canonical_url IS NOT NULL);


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
-- Name: index_message_attachments_on_message_and_attachment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_message_attachments_on_message_and_attachment ON public.conversation_message_attachments USING btree (conversation_message_id, stored_attachment_id);


--
-- Name: index_organizations_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_organizations_on_slug ON public.organizations USING btree (slug);


--
-- Name: index_outbound_email_deliveries_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbound_email_deliveries_on_idempotency ON public.outbound_email_deliveries USING btree (workspace_id, idempotency_key);


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
-- Name: index_pending_workspace_invitations_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_pending_workspace_invitations_on_email ON public.workspace_invitations USING btree (workspace_id, lower((email_address)::text)) WHERE ((status)::text = 'pending'::text);


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
-- Name: index_users_on_lower_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_lower_email_address ON public.users USING btree (lower((email_address)::text));


--
-- Name: index_users_on_unique_break_glass; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_unique_break_glass ON public.users USING btree (break_glass) WHERE break_glass;


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
-- Name: inbound_email_deliveries inbound_email_deliveries_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER inbound_email_deliveries_no_truncate BEFORE TRUNCATE ON public.inbound_email_deliveries FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_inbound_email_source_mutation();


--
-- Name: inbound_email_deliveries inbound_email_deliveries_protect_source; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER inbound_email_deliveries_protect_source BEFORE DELETE OR UPDATE ON public.inbound_email_deliveries FOR EACH ROW EXECUTE FUNCTION public.prevent_inbound_email_source_mutation();


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
-- Name: knowledge_sources knowledge_sources_protect_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_sources_protect_record BEFORE DELETE OR UPDATE ON public.knowledge_sources FOR EACH ROW EXECUTE FUNCTION public.protect_knowledge_source();


--
-- Name: knowledge_sources knowledge_sources_require_current_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER knowledge_sources_require_current_version AFTER INSERT OR UPDATE ON public.knowledge_sources DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.require_current_knowledge_version();


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
-- Name: workspaces workspaces_protect_runner_key; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER workspaces_protect_runner_key BEFORE UPDATE ON public.workspaces FOR EACH ROW EXECUTE FUNCTION public.protect_workspace_runner_key();


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
-- Name: crew_tasks fk_crew_tasks_owner; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_tasks
    ADD CONSTRAINT fk_crew_tasks_owner FOREIGN KEY (workspace_id, owner_membership_id, owner_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: knowledge_sources fk_knowledge_sources_current_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sources
    ADD CONSTRAINT fk_knowledge_sources_current_version FOREIGN KEY (workspace_id, id, current_version_id) REFERENCES public.knowledge_source_versions(workspace_id, knowledge_source_id, id);


--
-- Name: account_merges fk_rails_00215f0be3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT fk_rails_00215f0be3 FOREIGN KEY (unmerged_by_id) REFERENCES public.users(id);


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
-- Name: agent_profile_versions fk_rails_0a8ca6adb2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profile_versions
    ADD CONSTRAINT fk_rails_0a8ca6adb2 FOREIGN KEY (workspace_id, agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


--
-- Name: outbound_email_deliveries fk_rails_0e3170a70d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_0e3170a70d FOREIGN KEY (workspace_id, actor_membership_id) REFERENCES public.memberships(workspace_id, id);


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
-- Name: crew_task_events fk_rails_189fd006fb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_rails_189fd006fb FOREIGN KEY (workspace_id, crew_task_id) REFERENCES public.crew_tasks(workspace_id, id);


--
-- Name: email_drafts fk_rails_1aceaa280f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_rails_1aceaa280f FOREIGN KEY (workspace_id, email_thread_id, conversation_id) REFERENCES public.email_threads(workspace_id, id, conversation_id);


--
-- Name: crew_task_events fk_rails_25fca654f6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_rails_25fca654f6 FOREIGN KEY (actor_user_id) REFERENCES public.users(id);


--
-- Name: service_calendars fk_rails_28a2d1884f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_calendars
    ADD CONSTRAINT fk_rails_28a2d1884f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


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
-- Name: service_calendar_holidays fk_rails_4308962f7b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_calendar_holidays
    ADD CONSTRAINT fk_rails_4308962f7b FOREIGN KEY (workspace_id, service_calendar_id) REFERENCES public.service_calendars(workspace_id, id);


--
-- Name: knowledge_source_versions fk_rails_4502cdedde; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_versions
    ADD CONSTRAINT fk_rails_4502cdedde FOREIGN KEY (workspace_id, created_by_membership_id, created_by_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: case_slas fk_rails_480547c7a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_slas
    ADD CONSTRAINT fk_rails_480547c7a0 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: stored_attachments fk_rails_49367e49f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_attachments
    ADD CONSTRAINT fk_rails_49367e49f1 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


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
-- Name: conversation_message_attachments fk_rails_5474042175; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_message_attachments
    ADD CONSTRAINT fk_rails_5474042175 FOREIGN KEY (workspace_id, conversation_id, conversation_message_id) REFERENCES public.conversation_messages(workspace_id, conversation_id, id);


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
-- Name: email_drafts fk_rails_6106ba6ad3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_rails_6106ba6ad3 FOREIGN KEY (workspace_id, updated_by_id) REFERENCES public.memberships(workspace_id, user_id);


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
-- Name: identity_match_candidates fk_rails_687f013be7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates
    ADD CONSTRAINT fk_rails_687f013be7 FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


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
-- Name: support_cases fk_rails_6f0c83db70; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_cases
    ADD CONSTRAINT fk_rails_6f0c83db70 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: outbound_email_deliveries fk_rails_70d4e66122; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_70d4e66122 FOREIGN KEY (workspace_id, shared_email_inbox_id, email_thread_id, conversation_id) REFERENCES public.email_threads(workspace_id, shared_email_inbox_id, id, conversation_id);


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
-- Name: crew_task_events fk_rails_74f0d28011; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crew_task_events
    ADD CONSTRAINT fk_rails_74f0d28011 FOREIGN KEY (workspace_id, from_agent_profile_id) REFERENCES public.agent_profiles(workspace_id, id);


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
-- Name: agent_profiles fk_rails_89533dda30; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_profiles
    ADD CONSTRAINT fk_rails_89533dda30 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


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
-- Name: contact_merges fk_rails_93b8e9788d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges
    ADD CONSTRAINT fk_rails_93b8e9788d FOREIGN KEY (unmerged_by_id) REFERENCES public.users(id);


--
-- Name: case_notes fk_rails_971560bd73; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_notes
    ADD CONSTRAINT fk_rails_971560bd73 FOREIGN KEY (author_id) REFERENCES public.users(id);


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
-- Name: email_draft_attachments fk_rails_a6b8203129; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_draft_attachments
    ADD CONSTRAINT fk_rails_a6b8203129 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: outbound_email_deliveries fk_rails_a79332c57f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_a79332c57f FOREIGN KEY (actor_user_id) REFERENCES public.users(id);


--
-- Name: workspace_invitations fk_rails_aa0ff4982f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations
    ADD CONSTRAINT fk_rails_aa0ff4982f FOREIGN KEY (accepted_by_id) REFERENCES public.users(id);


--
-- Name: stored_attachments fk_rails_ab39bdb694; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_attachments
    ADD CONSTRAINT fk_rails_ab39bdb694 FOREIGN KEY (uploaded_by_user_id) REFERENCES public.users(id);


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
-- Name: outbound_email_deliveries fk_rails_b701b64a91; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_deliveries
    ADD CONSTRAINT fk_rails_b701b64a91 FOREIGN KEY (workspace_id, actor_membership_id, actor_user_id) REFERENCES public.memberships(workspace_id, id, user_id);


--
-- Name: email_message_links fk_rails_b76245f589; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_links
    ADD CONSTRAINT fk_rails_b76245f589 FOREIGN KEY (workspace_id, shared_email_inbox_id, email_thread_id, conversation_id) REFERENCES public.email_threads(workspace_id, shared_email_inbox_id, id, conversation_id);


--
-- Name: email_drafts fk_rails_b945d268da; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_drafts
    ADD CONSTRAINT fk_rails_b945d268da FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: accounts fk_rails_bac5365c2c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT fk_rails_bac5365c2c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


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
-- Name: knowledge_source_versions fk_rails_d40427c568; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_versions
    ADD CONSTRAINT fk_rails_d40427c568 FOREIGN KEY (workspace_id, stored_attachment_id) REFERENCES public.stored_attachments(workspace_id, id);


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
-- Name: email_threads fk_rails_ea636c8d06; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_threads
    ADD CONSTRAINT fk_rails_ea636c8d06 FOREIGN KEY (workspace_id, conversation_id) REFERENCES public.conversations(workspace_id, id);


--
-- Name: email_message_links fk_rails_edb13a72d9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_links
    ADD CONSTRAINT fk_rails_edb13a72d9 FOREIGN KEY (workspace_id, conversation_id, conversation_message_id) REFERENCES public.conversation_messages(workspace_id, conversation_id, id);


--
-- Name: outbound_email_delivery_attachments fk_rails_f20f8e12d5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_delivery_attachments
    ADD CONSTRAINT fk_rails_f20f8e12d5 FOREIGN KEY (workspace_id, outbound_email_delivery_id) REFERENCES public.outbound_email_deliveries(workspace_id, id);


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
-- Name: outbound_email_delivery_attachments fk_rails_f9dc4462b2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_email_delivery_attachments
    ADD CONSTRAINT fk_rails_f9dc4462b2 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: email_message_links fk_rails_fad997ec9c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_links
    ADD CONSTRAINT fk_rails_fad997ec9c FOREIGN KEY (workspace_id, shared_email_inbox_id) REFERENCES public.shared_email_inboxes(workspace_id, id);


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
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
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
