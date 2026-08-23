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
    CONSTRAINT audit_events_actor_kind CHECK (((actor_kind)::text = ANY ((ARRAY['user'::character varying, 'break_glass'::character varying, 'system'::character varying, 'anonymous'::character varying])::text[]))),
    CONSTRAINT audit_events_actor_presence CHECK ((((actor_kind)::text = ANY ((ARRAY['user'::character varying, 'break_glass'::character varying])::text[])) = (actor_id IS NOT NULL))),
    CONSTRAINT audit_events_source CHECK (((source)::text = ANY ((ARRAY['web'::character varying, 'job'::character varying, 'task'::character varying, 'runner'::character varying, 'integration'::character varying, 'system'::character varying])::text[])))
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
    CONSTRAINT identity_match_candidates_key_kind CHECK (((key_kind)::text = ANY ((ARRAY['email'::character varying, 'domain'::character varying])::text[]))),
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
    CONSTRAINT memberships_role CHECK (((role)::text = ANY ((ARRAY['owner'::character varying, 'admin'::character varying, 'manager'::character varying, 'member'::character varying, 'viewer'::character varying])::text[])))
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
    CONSTRAINT sessions_authentication_method CHECK (((authentication_method)::text = ANY ((ARRAY['local'::character varying, 'break_glass'::character varying])::text[])))
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
    CONSTRAINT source_identities_entity_kind CHECK (((entity_kind)::text = ANY ((ARRAY['account'::character varying, 'contact'::character varying])::text[]))),
    CONSTRAINT source_identities_resolution_method CHECK (((resolution_method IS NULL) OR ((resolution_method)::text = ANY ((ARRAY['created'::character varying, 'deterministic'::character varying, 'reviewed'::character varying])::text[])))),
    CONSTRAINT source_identities_resolution_state CHECK (((((status)::text = ANY ((ARRAY['pending'::character varying, 'ambiguous'::character varying])::text[])) AND (account_id IS NULL) AND (contact_id IS NULL) AND (resolution_method IS NULL) AND (resolved_by_id IS NULL) AND (resolved_at IS NULL)) OR (((status)::text = 'matched'::text) AND ((((entity_kind)::text = 'account'::text) AND (account_id IS NOT NULL) AND (contact_id IS NULL)) OR (((entity_kind)::text = 'contact'::text) AND (contact_id IS NOT NULL) AND (account_id IS NULL))) AND (resolution_method IS NOT NULL) AND (resolved_at IS NOT NULL)))),
    CONSTRAINT source_identities_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'ambiguous'::character varying, 'matched'::character varying])::text[])))
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
    CONSTRAINT source_identity_keys_kind CHECK (((kind)::text = ANY ((ARRAY['email'::character varying, 'domain'::character varying])::text[])))
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
    CONSTRAINT workspace_invitations_role CHECK (((role)::text = ANY ((ARRAY['owner'::character varying, 'admin'::character varying, 'manager'::character varying, 'member'::character varying, 'viewer'::character varying])::text[]))),
    CONSTRAINT workspace_invitations_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'revoked'::character varying, 'expired'::character varying])::text[])))
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
-- Name: contact_merges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges ALTER COLUMN id SET DEFAULT nextval('public.contact_merges_id_seq'::regclass);


--
-- Name: contacts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts ALTER COLUMN id SET DEFAULT nextval('public.contacts_id_seq'::regclass);


--
-- Name: identity_match_candidates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates ALTER COLUMN id SET DEFAULT nextval('public.identity_match_candidates_id_seq'::regclass);


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
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: source_identities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identities ALTER COLUMN id SET DEFAULT nextval('public.source_identities_id_seq'::regclass);


--
-- Name: source_identity_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identity_keys ALTER COLUMN id SET DEFAULT nextval('public.source_identity_keys_id_seq'::regclass);


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
-- Name: identity_match_candidates identity_match_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates
    ADD CONSTRAINT identity_match_candidates_pkey PRIMARY KEY (id);


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
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


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
-- Name: index_current_source_identity_keys; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_current_source_identity_keys ON public.source_identity_keys USING btree (source_identity_id, kind, normalized_value) WHERE (retired_at IS NULL);


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
-- Name: index_sessions_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_expires_at ON public.sessions USING btree (expires_at);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


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
-- Name: account_merges fk_rails_00215f0be3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_merges
    ADD CONSTRAINT fk_rails_00215f0be3 FOREIGN KEY (unmerged_by_id) REFERENCES public.users(id);


--
-- Name: contact_merges fk_rails_105e45e7a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges
    ADD CONSTRAINT fk_rails_105e45e7a0 FOREIGN KEY (merged_by_id) REFERENCES public.users(id);


--
-- Name: workspaces fk_rails_3e6d59991e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT fk_rails_3e6d59991e FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


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
-- Name: source_identities fk_rails_606ea51223; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identities
    ADD CONSTRAINT fk_rails_606ea51223 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


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
-- Name: identity_match_candidates fk_rails_687f013be7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates
    ADD CONSTRAINT fk_rails_687f013be7 FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


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
-- Name: source_identities fk_rails_7e80950554; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identities
    ADD CONSTRAINT fk_rails_7e80950554 FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: source_identity_keys fk_rails_8aa9bbdb8d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_identity_keys
    ADD CONSTRAINT fk_rails_8aa9bbdb8d FOREIGN KEY (workspace_id, source_identity_id) REFERENCES public.source_identities(workspace_id, id);


--
-- Name: contact_merges fk_rails_93b8e9788d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_merges
    ADD CONSTRAINT fk_rails_93b8e9788d FOREIGN KEY (unmerged_by_id) REFERENCES public.users(id);


--
-- Name: memberships fk_rails_99326fb65d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_99326fb65d FOREIGN KEY (user_id) REFERENCES public.users(id);


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
-- Name: identity_match_candidates fk_rails_b43f253bd6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_match_candidates
    ADD CONSTRAINT fk_rails_b43f253bd6 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: accounts fk_rails_bac5365c2c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT fk_rails_bac5365c2c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: audit_events fk_rails_cdb00c0cbd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_cdb00c0cbd FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: audit_events fk_rails_dd1f3a471a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_dd1f3a471a FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: memberships fk_rails_e7b442f67c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_e7b442f67c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


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

