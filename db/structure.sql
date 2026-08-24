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
    updated_at timestamp(6) without time zone NOT NULL
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
    CONSTRAINT inbound_email_deliveries_failure_code CHECK (((failure_code IS NULL) OR ((failure_code)::text = ANY ((ARRAY['parse_error'::character varying, 'missing_sender'::character varying, 'missing_message_id'::character varying, 'message_id_conflict'::character varying, 'empty_body'::character varying, 'body_too_large'::character varying, 'identity_ambiguous'::character varying, 'identity_error'::character varying, 'persistence_error'::character varying])::text[])))),
    CONSTRAINT inbound_email_deliveries_size CHECK ((octet_length(raw_email) <= 10485760)),
    CONSTRAINT inbound_email_deliveries_state CHECK (((((status)::text = 'received'::text) AND (failure_code IS NULL) AND (conversation_id IS NULL) AND (conversation_message_id IS NULL) AND (processed_at IS NULL)) OR (((status)::text = 'processed'::text) AND (failure_code IS NULL) AND (conversation_id IS NOT NULL) AND (conversation_message_id IS NOT NULL) AND (processed_at IS NOT NULL)) OR (((status)::text = 'failed'::text) AND (failure_code IS NOT NULL) AND (conversation_id IS NULL) AND (conversation_message_id IS NULL) AND (processed_at IS NOT NULL)))),
    CONSTRAINT inbound_email_deliveries_status CHECK (((status)::text = ANY ((ARRAY['received'::character varying, 'processed'::character varying, 'failed'::character varying])::text[])))
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
    updated_at timestamp(6) without time zone NOT NULL
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
-- Name: conversation_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages ALTER COLUMN id SET DEFAULT nextval('public.conversation_messages_id_seq'::regclass);


--
-- Name: conversations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations ALTER COLUMN id SET DEFAULT nextval('public.conversations_id_seq'::regclass);


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
-- Name: memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships ALTER COLUMN id SET DEFAULT nextval('public.memberships_id_seq'::regclass);


--
-- Name: organizations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations ALTER COLUMN id SET DEFAULT nextval('public.organizations_id_seq'::regclass);


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
-- Name: idx_on_service_calendar_id_date_e0bbb87882; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_service_calendar_id_date_e0bbb87882 ON public.service_calendar_holidays USING btree (service_calendar_id, date);


--
-- Name: idx_on_shared_email_inbox_id_message_id_2a2dabc074; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_shared_email_inbox_id_message_id_2a2dabc074 ON public.email_message_links USING btree (shared_email_inbox_id, message_id);


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
-- Name: index_current_source_identity_keys; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_current_source_identity_keys ON public.source_identity_keys USING btree (source_identity_id, kind, normalized_value) WHERE (retired_at IS NULL);


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
-- Name: index_organizations_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_organizations_on_slug ON public.organizations USING btree (slug);


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
-- Name: conversation_messages conversation_messages_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER conversation_messages_append_only BEFORE DELETE OR UPDATE ON public.conversation_messages FOR EACH ROW EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: conversation_messages conversation_messages_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER conversation_messages_no_truncate BEFORE TRUNCATE ON public.conversation_messages FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


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
-- Name: support_case_status_changes support_case_status_changes_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER support_case_status_changes_append_only BEFORE DELETE OR UPDATE ON public.support_case_status_changes FOR EACH ROW EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


--
-- Name: support_case_status_changes support_case_status_changes_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER support_case_status_changes_no_truncate BEFORE TRUNCATE ON public.support_case_status_changes FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_helpdesk_record_mutation();


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
-- Name: account_merges fk_rails_00215f0be3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT fk_rails_00215f0be3 FOREIGN KEY (unmerged_by_id) REFERENCES public.users(id);


--
-- Name: case_slas fk_rails_048a2ba7c7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_slas
    ADD CONSTRAINT fk_rails_048a2ba7c7 FOREIGN KEY (workspace_id, sla_policy_id) REFERENCES public.sla_policies(workspace_id, id);


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
-- Name: service_calendar_holidays fk_rails_3efa0e2453; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_calendar_holidays
    ADD CONSTRAINT fk_rails_3efa0e2453 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


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
-- Name: case_slas fk_rails_480547c7a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_slas
    ADD CONSTRAINT fk_rails_480547c7a0 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: sla_escalation_tasks fk_rails_4c05045338; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_escalation_tasks
    ADD CONSTRAINT fk_rails_4c05045338 FOREIGN KEY (workspace_id, case_sla_id) REFERENCES public.case_slas(workspace_id, id);


--
-- Name: account_merges fk_rails_4f29f8ae3c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT fk_rails_4f29f8ae3c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


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
-- Name: source_identities fk_rails_606ea51223; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identities
    ADD CONSTRAINT fk_rails_606ea51223 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


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
-- Name: conversation_messages fk_rails_69e4535daa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages
    ADD CONSTRAINT fk_rails_69e4535daa FOREIGN KEY (workspace_id, author_contact_id) REFERENCES public.contacts(workspace_id, id);


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
-- Name: account_merges fk_rails_73bbb32f1d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT fk_rails_73bbb32f1d FOREIGN KEY (merged_by_id) REFERENCES public.users(id);


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
-- Name: conversation_messages fk_rails_7c459f2c0a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages
    ADD CONSTRAINT fk_rails_7c459f2c0a FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


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
-- Name: workspace_invitations fk_rails_aa0ff4982f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations
    ADD CONSTRAINT fk_rails_aa0ff4982f FOREIGN KEY (accepted_by_id) REFERENCES public.users(id);


--
-- Name: identity_match_candidates fk_rails_ac435a87c8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates
    ADD CONSTRAINT fk_rails_ac435a87c8 FOREIGN KEY (workspace_id, source_identity_id) REFERENCES public.source_identities(workspace_id, id);


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
-- Name: email_message_links fk_rails_b76245f589; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_links
    ADD CONSTRAINT fk_rails_b76245f589 FOREIGN KEY (workspace_id, shared_email_inbox_id, email_thread_id, conversation_id) REFERENCES public.email_threads(workspace_id, shared_email_inbox_id, id, conversation_id);


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
-- Name: shared_email_inboxes fk_rails_c70ce652a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shared_email_inboxes
    ADD CONSTRAINT fk_rails_c70ce652a0 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: conversation_messages fk_rails_cd0fa9de6c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_messages
    ADD CONSTRAINT fk_rails_cd0fa9de6c FOREIGN KEY (author_user_id) REFERENCES public.users(id);


--
-- Name: audit_events fk_rails_cdb00c0cbd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_cdb00c0cbd FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


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
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
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
