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
-- Name: prevent_lab_version_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_lab_version_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION 'lab versions are immutable'; END; $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

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
    CONSTRAINT audit_events_source CHECK (((source)::text = ANY (ARRAY[('web'::character varying)::text, ('job'::character varying)::text, ('task'::character varying)::text, ('integration'::character varying)::text, ('system'::character varying)::text])))
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
-- Name: calibration_predictions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calibration_predictions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    calibration_sample_id bigint NOT NULL,
    result jsonb NOT NULL,
    processing_version character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_85764e7b74 CHECK (((jsonb_typeof(result) = 'object'::text) AND ((result ->> 'decision'::text) = ANY (ARRAY['pass'::text, 'fail'::text, 'abstain'::text, 'error'::text]))))
);


--
-- Name: calibration_predictions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calibration_predictions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calibration_predictions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calibration_predictions_id_seq OWNED BY public.calibration_predictions.id;


--
-- Name: calibration_samples; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calibration_samples (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    calibration_set_id bigint NOT NULL,
    grader_version_id bigint NOT NULL,
    eval_case_check_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    cohort character varying NOT NULL,
    output_digest character varying NOT NULL,
    output jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_223ca5464b CHECK ((((cohort)::text = ANY ((ARRAY['development'::character varying, 'held_out'::character varying])::text[])) AND (jsonb_typeof(output) = 'object'::text)))
);


--
-- Name: calibration_samples_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calibration_samples_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calibration_samples_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calibration_samples_id_seq OWNED BY public.calibration_samples.id;


--
-- Name: calibration_sets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calibration_sets (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    grader_version_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: calibration_sets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calibration_sets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calibration_sets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calibration_sets_id_seq OWNED BY public.calibration_sets.id;


--
-- Name: cluster_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cluster_members (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    issue_cluster_id bigint NOT NULL,
    corpus_item_id bigint NOT NULL,
    signals jsonb DEFAULT '[]'::jsonb NOT NULL,
    selection_reason text
);


--
-- Name: cluster_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cluster_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cluster_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cluster_members_id_seq OWNED BY public.cluster_members.id;


--
-- Name: corpora; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.corpora (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: corpora_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.corpora_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: corpora_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.corpora_id_seq OWNED BY public.corpora.id;


--
-- Name: corpus_analyses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.corpus_analyses (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    requested_by_id bigint NOT NULL,
    processing_method character varying NOT NULL,
    state character varying DEFAULT 'queued'::character varying NOT NULL,
    scenario_limit integer NOT NULL,
    error text,
    summary jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_eb878e98a6 CHECK ((((state)::text = ANY (ARRAY[('queued'::character varying)::text, ('complete'::character varying)::text, ('failed'::character varying)::text])) AND ((scenario_limit >= 1) AND (scenario_limit <= 100))))
);


--
-- Name: corpus_analyses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.corpus_analyses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: corpus_analyses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.corpus_analyses_id_seq OWNED BY public.corpus_analyses.id;


--
-- Name: corpus_analysis_inputs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.corpus_analysis_inputs (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    corpus_analysis_id bigint NOT NULL,
    corpus_item_id bigint NOT NULL
);


--
-- Name: corpus_analysis_inputs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.corpus_analysis_inputs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: corpus_analysis_inputs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.corpus_analysis_inputs_id_seq OWNED BY public.corpus_analysis_inputs.id;


--
-- Name: corpus_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.corpus_items (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    source_snapshot_id bigint NOT NULL,
    external_id character varying NOT NULL,
    title character varying NOT NULL,
    content text NOT NULL,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_ab75a1fb7b CHECK (((jsonb_typeof(context) = 'object'::text) AND ((length(content) >= 1) AND (length(content) <= 100000))))
);


--
-- Name: corpus_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.corpus_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: corpus_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.corpus_items_id_seq OWNED BY public.corpus_items.id;


--
-- Name: eval_case_checks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.eval_case_checks (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    eval_case_id bigint NOT NULL,
    scenario_version_id bigint NOT NULL,
    scenario_evidence_id bigint NOT NULL,
    grader_version_id bigint NOT NULL,
    requirement_kind character varying NOT NULL,
    requirement_index integer NOT NULL,
    CONSTRAINT chk_rails_0711ec2a7e CHECK ((((requirement_kind)::text = ANY (ARRAY[('outcomes'::character varying)::text, ('actions'::character varying)::text, ('forbidden'::character varying)::text, ('escalation'::character varying)::text, ('grounding'::character varying)::text])) AND ((requirement_index >= 0) AND (requirement_index <= 19))))
);


--
-- Name: eval_case_checks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.eval_case_checks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: eval_case_checks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.eval_case_checks_id_seq OWNED BY public.eval_case_checks.id;


--
-- Name: eval_cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.eval_cases (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    scenario_version_id bigint NOT NULL,
    scenario_review_id bigint NOT NULL,
    compiled_by_id bigint NOT NULL,
    number integer NOT NULL,
    compiler_version character varying NOT NULL,
    definition_digest character varying NOT NULL,
    contract jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_12b04d0fce CHECK (((number > 0) AND (jsonb_typeof(contract) = 'object'::text)))
);


--
-- Name: eval_cases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.eval_cases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: eval_cases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.eval_cases_id_seq OWNED BY public.eval_cases.id;


--
-- Name: eval_suite_cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.eval_suite_cases (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    eval_suite_id bigint NOT NULL,
    eval_case_id bigint NOT NULL
);


--
-- Name: eval_suite_cases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.eval_suite_cases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: eval_suite_cases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.eval_suite_cases_id_seq OWNED BY public.eval_suite_cases.id;


--
-- Name: eval_suites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.eval_suites (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    name character varying NOT NULL,
    kind character varying DEFAULT 'evaluation'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_b35cd7079f CHECK (((kind)::text = ANY (ARRAY[('evaluation'::character varying)::text, ('regression'::character varying)::text])))
);


--
-- Name: eval_suites_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.eval_suites_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: eval_suites_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.eval_suites_id_seq OWNED BY public.eval_suites.id;


--
-- Name: grader_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.grader_versions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    grader_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    number integer NOT NULL,
    kind character varying NOT NULL,
    processing_version character varying NOT NULL,
    definition jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_c8ce9f5a75 CHECK (((number > 0) AND ((kind)::text = ANY (ARRAY[('deterministic'::character varying)::text, ('rubric_judge'::character varying)::text])) AND (jsonb_typeof(definition) = 'object'::text)))
);


--
-- Name: grader_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.grader_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: grader_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.grader_versions_id_seq OWNED BY public.grader_versions.id;


--
-- Name: graders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.graders (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    name character varying NOT NULL,
    current_version_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: graders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.graders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: graders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.graders_id_seq OWNED BY public.graders.id;


--
-- Name: human_labels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.human_labels (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    calibration_sample_id bigint NOT NULL,
    labelled_by_id bigint NOT NULL,
    decision character varying NOT NULL,
    rationale text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_e87f64985c CHECK ((((decision)::text = ANY ((ARRAY['pass'::character varying, 'fail'::character varying, 'uncertain'::character varying])::text[])) AND ((length(rationale) >= 1) AND (length(rationale) <= 2000))))
);


--
-- Name: human_labels_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.human_labels_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: human_labels_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.human_labels_id_seq OWNED BY public.human_labels.id;


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
-- Name: issue_clusters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_clusters (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    corpus_analysis_id bigint NOT NULL,
    proposed_label character varying NOT NULL,
    signals jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: issue_clusters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.issue_clusters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: issue_clusters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.issue_clusters_id_seq OWNED BY public.issue_clusters.id;


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
-- Name: scenario_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scenario_evidence (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    scenario_version_id bigint NOT NULL,
    corpus_item_id bigint NOT NULL,
    kind character varying NOT NULL,
    excerpt text NOT NULL,
    CONSTRAINT chk_rails_6cd9bf465e CHECK ((((kind)::text = ANY (ARRAY[('expectation'::character varying)::text, ('knowledge'::character varying)::text])) AND ((length(excerpt) >= 1) AND (length(excerpt) <= 4000))))
);


--
-- Name: scenario_evidence_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.scenario_evidence_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scenario_evidence_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.scenario_evidence_id_seq OWNED BY public.scenario_evidence.id;


--
-- Name: scenario_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scenario_reviews (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    scenario_version_id bigint NOT NULL,
    reviewed_by_id bigint NOT NULL,
    decision character varying NOT NULL,
    note text NOT NULL,
    merged_version_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_b908de4663 CHECK ((((decision)::text = ANY (ARRAY[('approve'::character varying)::text, ('reject'::character varying)::text, ('merge'::character varying)::text])) AND (((decision)::text = 'merge'::text) = (merged_version_id IS NOT NULL))))
);


--
-- Name: scenario_reviews_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.scenario_reviews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scenario_reviews_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.scenario_reviews_id_seq OWNED BY public.scenario_reviews.id;


--
-- Name: scenario_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scenario_versions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    scenario_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    number integer NOT NULL,
    origin character varying NOT NULL,
    title character varying NOT NULL,
    situation text NOT NULL,
    taxonomy_label character varying NOT NULL,
    importance character varying NOT NULL,
    known_facts jsonb DEFAULT '{}'::jsonb NOT NULL,
    hidden_facts jsonb DEFAULT '{}'::jsonb NOT NULL,
    requirements jsonb DEFAULT '{}'::jsonb NOT NULL,
    mutation jsonb DEFAULT '{}'::jsonb NOT NULL,
    selection_reason text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_4d6bffc7f8 CHECK (((number > 0) AND ((origin)::text = ANY (ARRAY[('mined'::character varying)::text, ('expert'::character varying)::text, ('variant'::character varying)::text])) AND ((importance)::text = ANY (ARRAY[('normal'::character varying)::text, ('high'::character varying)::text, ('critical'::character varying)::text])) AND (jsonb_typeof(known_facts) = 'object'::text) AND (jsonb_typeof(hidden_facts) = 'object'::text) AND (jsonb_typeof(requirements) = 'object'::text)))
);


--
-- Name: scenario_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.scenario_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scenario_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.scenario_versions_id_seq OWNED BY public.scenario_versions.id;


--
-- Name: scenarios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scenarios (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    corpus_item_id bigint NOT NULL,
    cluster_member_id bigint,
    parent_version_id bigint,
    current_version_id bigint,
    merged_into_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: scenarios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.scenarios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scenarios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.scenarios_id_seq OWNED BY public.scenarios.id;


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
-- Name: source_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_snapshots (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    source_id bigint NOT NULL,
    number integer NOT NULL,
    digest character varying NOT NULL,
    redaction character varying NOT NULL,
    processing_version character varying NOT NULL,
    imported_by_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_75987cdd84 CHECK (((number > 0) AND ((digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((redaction)::text = ANY (ARRAY[('email'::character varying)::text, ('none'::character varying)::text]))))
);


--
-- Name: source_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.source_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: source_snapshots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.source_snapshots_id_seq OWNED BY public.source_snapshots.id;


--
-- Name: sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sources (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    name character varying NOT NULL,
    kind character varying NOT NULL,
    current_snapshot_id bigint,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_5a3ed6bc52 CHECK (((kind)::text = ANY (ARRAY[('conversations'::character varying)::text, ('document'::character varying)::text])))
);


--
-- Name: sources_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sources_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sources_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sources_id_seq OWNED BY public.sources.id;


--
-- Name: taxonomy_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.taxonomy_versions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    corpus_analysis_id bigint NOT NULL,
    reviewed_by_id bigint NOT NULL,
    number integer NOT NULL,
    labels jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: taxonomy_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.taxonomy_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: taxonomy_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.taxonomy_versions_id_seq OWNED BY public.taxonomy_versions.id;


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
-- Name: audit_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ALTER COLUMN id SET DEFAULT nextval('public.audit_events_id_seq'::regclass);


--
-- Name: calibration_predictions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_predictions ALTER COLUMN id SET DEFAULT nextval('public.calibration_predictions_id_seq'::regclass);


--
-- Name: calibration_samples id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_samples ALTER COLUMN id SET DEFAULT nextval('public.calibration_samples_id_seq'::regclass);


--
-- Name: calibration_sets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_sets ALTER COLUMN id SET DEFAULT nextval('public.calibration_sets_id_seq'::regclass);


--
-- Name: cluster_members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cluster_members ALTER COLUMN id SET DEFAULT nextval('public.cluster_members_id_seq'::regclass);


--
-- Name: corpora id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpora ALTER COLUMN id SET DEFAULT nextval('public.corpora_id_seq'::regclass);


--
-- Name: corpus_analyses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analyses ALTER COLUMN id SET DEFAULT nextval('public.corpus_analyses_id_seq'::regclass);


--
-- Name: corpus_analysis_inputs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analysis_inputs ALTER COLUMN id SET DEFAULT nextval('public.corpus_analysis_inputs_id_seq'::regclass);


--
-- Name: corpus_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_items ALTER COLUMN id SET DEFAULT nextval('public.corpus_items_id_seq'::regclass);


--
-- Name: eval_case_checks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_case_checks ALTER COLUMN id SET DEFAULT nextval('public.eval_case_checks_id_seq'::regclass);


--
-- Name: eval_cases id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_cases ALTER COLUMN id SET DEFAULT nextval('public.eval_cases_id_seq'::regclass);


--
-- Name: eval_suite_cases id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_suite_cases ALTER COLUMN id SET DEFAULT nextval('public.eval_suite_cases_id_seq'::regclass);


--
-- Name: eval_suites id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_suites ALTER COLUMN id SET DEFAULT nextval('public.eval_suites_id_seq'::regclass);


--
-- Name: grader_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grader_versions ALTER COLUMN id SET DEFAULT nextval('public.grader_versions_id_seq'::regclass);


--
-- Name: graders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.graders ALTER COLUMN id SET DEFAULT nextval('public.graders_id_seq'::regclass);


--
-- Name: human_labels id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.human_labels ALTER COLUMN id SET DEFAULT nextval('public.human_labels_id_seq'::regclass);


--
-- Name: installation_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.installation_states ALTER COLUMN id SET DEFAULT nextval('public.installation_states_id_seq'::regclass);


--
-- Name: issue_clusters id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_clusters ALTER COLUMN id SET DEFAULT nextval('public.issue_clusters_id_seq'::regclass);


--
-- Name: memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships ALTER COLUMN id SET DEFAULT nextval('public.memberships_id_seq'::regclass);


--
-- Name: oidc_identities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_identities ALTER COLUMN id SET DEFAULT nextval('public.oidc_identities_id_seq'::regclass);


--
-- Name: organizations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations ALTER COLUMN id SET DEFAULT nextval('public.organizations_id_seq'::regclass);


--
-- Name: scenario_evidence id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_evidence ALTER COLUMN id SET DEFAULT nextval('public.scenario_evidence_id_seq'::regclass);


--
-- Name: scenario_reviews id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_reviews ALTER COLUMN id SET DEFAULT nextval('public.scenario_reviews_id_seq'::regclass);


--
-- Name: scenario_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_versions ALTER COLUMN id SET DEFAULT nextval('public.scenario_versions_id_seq'::regclass);


--
-- Name: scenarios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenarios ALTER COLUMN id SET DEFAULT nextval('public.scenarios_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: source_snapshots id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_snapshots ALTER COLUMN id SET DEFAULT nextval('public.source_snapshots_id_seq'::regclass);


--
-- Name: sources id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources ALTER COLUMN id SET DEFAULT nextval('public.sources_id_seq'::regclass);


--
-- Name: taxonomy_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taxonomy_versions ALTER COLUMN id SET DEFAULT nextval('public.taxonomy_versions_id_seq'::regclass);


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
-- Name: calibration_predictions calibration_predictions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_predictions
    ADD CONSTRAINT calibration_predictions_pkey PRIMARY KEY (id);


--
-- Name: calibration_samples calibration_samples_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_samples
    ADD CONSTRAINT calibration_samples_pkey PRIMARY KEY (id);


--
-- Name: calibration_sets calibration_sets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_sets
    ADD CONSTRAINT calibration_sets_pkey PRIMARY KEY (id);


--
-- Name: cluster_members cluster_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cluster_members
    ADD CONSTRAINT cluster_members_pkey PRIMARY KEY (id);


--
-- Name: corpora corpora_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpora
    ADD CONSTRAINT corpora_pkey PRIMARY KEY (id);


--
-- Name: corpus_analyses corpus_analyses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analyses
    ADD CONSTRAINT corpus_analyses_pkey PRIMARY KEY (id);


--
-- Name: corpus_analysis_inputs corpus_analysis_inputs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analysis_inputs
    ADD CONSTRAINT corpus_analysis_inputs_pkey PRIMARY KEY (id);


--
-- Name: corpus_items corpus_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_items
    ADD CONSTRAINT corpus_items_pkey PRIMARY KEY (id);


--
-- Name: eval_case_checks eval_case_checks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_case_checks
    ADD CONSTRAINT eval_case_checks_pkey PRIMARY KEY (id);


--
-- Name: eval_cases eval_cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_cases
    ADD CONSTRAINT eval_cases_pkey PRIMARY KEY (id);


--
-- Name: eval_suite_cases eval_suite_cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_suite_cases
    ADD CONSTRAINT eval_suite_cases_pkey PRIMARY KEY (id);


--
-- Name: eval_suites eval_suites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_suites
    ADD CONSTRAINT eval_suites_pkey PRIMARY KEY (id);


--
-- Name: grader_versions grader_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grader_versions
    ADD CONSTRAINT grader_versions_pkey PRIMARY KEY (id);


--
-- Name: graders graders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.graders
    ADD CONSTRAINT graders_pkey PRIMARY KEY (id);


--
-- Name: human_labels human_labels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.human_labels
    ADD CONSTRAINT human_labels_pkey PRIMARY KEY (id);


--
-- Name: installation_states installation_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.installation_states
    ADD CONSTRAINT installation_states_pkey PRIMARY KEY (id);


--
-- Name: issue_clusters issue_clusters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_clusters
    ADD CONSTRAINT issue_clusters_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);


--
-- Name: oidc_identities oidc_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_identities
    ADD CONSTRAINT oidc_identities_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: scenario_evidence scenario_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_evidence
    ADD CONSTRAINT scenario_evidence_pkey PRIMARY KEY (id);


--
-- Name: scenario_reviews scenario_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_reviews
    ADD CONSTRAINT scenario_reviews_pkey PRIMARY KEY (id);


--
-- Name: scenario_versions scenario_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_versions
    ADD CONSTRAINT scenario_versions_pkey PRIMARY KEY (id);


--
-- Name: scenarios scenarios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenarios
    ADD CONSTRAINT scenarios_pkey PRIMARY KEY (id);


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
-- Name: source_snapshots source_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_snapshots
    ADD CONSTRAINT source_snapshots_pkey PRIMARY KEY (id);


--
-- Name: sources sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_pkey PRIMARY KEY (id);


--
-- Name: taxonomy_versions taxonomy_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taxonomy_versions
    ADD CONSTRAINT taxonomy_versions_pkey PRIMARY KEY (id);


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
-- Name: calibration_sample_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX calibration_sample_identity ON public.calibration_samples USING btree (calibration_set_id, eval_case_check_id, output_digest);


--
-- Name: idx_on_calibration_sample_id_labelled_by_id_id_848426ae0f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_calibration_sample_id_labelled_by_id_id_848426ae0f ON public.human_labels USING btree (calibration_sample_id, labelled_by_id, id);


--
-- Name: idx_on_corpus_analysis_id_corpus_item_id_454c89de9d; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_corpus_analysis_id_corpus_item_id_454c89de9d ON public.corpus_analysis_inputs USING btree (corpus_analysis_id, corpus_item_id);


--
-- Name: idx_on_eval_case_id_requirement_kind_requirement_in_8a3502f15b; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_eval_case_id_requirement_kind_requirement_in_8a3502f15b ON public.eval_case_checks USING btree (eval_case_id, requirement_kind, requirement_index);


--
-- Name: idx_on_scenario_version_id_corpus_item_id_kind_455675656f; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_scenario_version_id_corpus_item_id_kind_455675656f ON public.scenario_evidence USING btree (scenario_version_id, corpus_item_id, kind);


--
-- Name: idx_on_workspace_id_corpus_id_grader_id_id_69031213be; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_grader_id_id_69031213be ON public.grader_versions USING btree (workspace_id, corpus_id, grader_id, id);


--
-- Name: idx_on_workspace_id_corpus_id_id_grader_version_id_a2829702f1; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_id_grader_version_id_a2829702f1 ON public.eval_case_checks USING btree (workspace_id, corpus_id, id, grader_version_id);


--
-- Name: idx_on_workspace_id_corpus_id_id_grader_version_id_b83f9fb296; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_id_grader_version_id_b83f9fb296 ON public.calibration_sets USING btree (workspace_id, corpus_id, id, grader_version_id);


--
-- Name: idx_on_workspace_id_corpus_id_id_scenario_version_i_a23e825ae5; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_id_scenario_version_i_a23e825ae5 ON public.eval_cases USING btree (workspace_id, corpus_id, id, scenario_version_id);


--
-- Name: idx_on_workspace_id_corpus_id_scenario_id_id_3bbb59a428; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_scenario_id_id_3bbb59a428 ON public.scenario_versions USING btree (workspace_id, corpus_id, scenario_id, id);


--
-- Name: idx_on_workspace_id_corpus_id_scenario_version_id_i_5b28007b2f; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_scenario_version_id_i_5b28007b2f ON public.scenario_reviews USING btree (workspace_id, corpus_id, scenario_version_id, id);


--
-- Name: idx_on_workspace_id_corpus_id_scenario_version_id_i_f1f6e32c78; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_scenario_version_id_i_f1f6e32c78 ON public.scenario_evidence USING btree (workspace_id, corpus_id, scenario_version_id, id);


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
-- Name: index_calibration_predictions_on_calibration_sample_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_calibration_predictions_on_calibration_sample_id ON public.calibration_predictions USING btree (calibration_sample_id);


--
-- Name: index_calibration_samples_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calibration_samples_on_created_by_id ON public.calibration_samples USING btree (created_by_id);


--
-- Name: index_calibration_samples_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_calibration_samples_on_workspace_id_and_corpus_id_and_id ON public.calibration_samples USING btree (workspace_id, corpus_id, id);


--
-- Name: index_calibration_sets_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calibration_sets_on_created_by_id ON public.calibration_sets USING btree (created_by_id);


--
-- Name: index_cluster_members_on_issue_cluster_id_and_corpus_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_cluster_members_on_issue_cluster_id_and_corpus_item_id ON public.cluster_members USING btree (issue_cluster_id, corpus_item_id);


--
-- Name: index_cluster_members_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_cluster_members_on_workspace_id_and_corpus_id_and_id ON public.cluster_members USING btree (workspace_id, corpus_id, id);


--
-- Name: index_corpora_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_corpora_on_workspace_id ON public.corpora USING btree (workspace_id);


--
-- Name: index_corpora_on_workspace_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_corpora_on_workspace_id_and_id ON public.corpora USING btree (workspace_id, id);


--
-- Name: index_corpus_analyses_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_corpus_analyses_on_requested_by_id ON public.corpus_analyses USING btree (requested_by_id);


--
-- Name: index_corpus_analyses_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_corpus_analyses_on_workspace_id_and_corpus_id_and_id ON public.corpus_analyses USING btree (workspace_id, corpus_id, id);


--
-- Name: index_corpus_items_on_source_snapshot_id_and_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_corpus_items_on_source_snapshot_id_and_external_id ON public.corpus_items USING btree (source_snapshot_id, external_id);


--
-- Name: index_corpus_items_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_corpus_items_on_workspace_id_and_corpus_id_and_id ON public.corpus_items USING btree (workspace_id, corpus_id, id);


--
-- Name: index_eval_case_checks_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_eval_case_checks_on_workspace_id_and_corpus_id_and_id ON public.eval_case_checks USING btree (workspace_id, corpus_id, id);


--
-- Name: index_eval_cases_on_compiled_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_eval_cases_on_compiled_by_id ON public.eval_cases USING btree (compiled_by_id);


--
-- Name: index_eval_cases_on_scenario_version_id_and_definition_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_eval_cases_on_scenario_version_id_and_definition_digest ON public.eval_cases USING btree (scenario_version_id, definition_digest);


--
-- Name: index_eval_cases_on_scenario_version_id_and_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_eval_cases_on_scenario_version_id_and_number ON public.eval_cases USING btree (scenario_version_id, number);


--
-- Name: index_eval_cases_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_eval_cases_on_workspace_id_and_corpus_id_and_id ON public.eval_cases USING btree (workspace_id, corpus_id, id);


--
-- Name: index_eval_suite_cases_on_eval_suite_id_and_eval_case_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_eval_suite_cases_on_eval_suite_id_and_eval_case_id ON public.eval_suite_cases USING btree (eval_suite_id, eval_case_id);


--
-- Name: index_eval_suites_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_eval_suites_on_workspace_id_and_corpus_id_and_id ON public.eval_suites USING btree (workspace_id, corpus_id, id);


--
-- Name: index_grader_versions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_grader_versions_on_created_by_id ON public.grader_versions USING btree (created_by_id);


--
-- Name: index_grader_versions_on_grader_id_and_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_grader_versions_on_grader_id_and_number ON public.grader_versions USING btree (grader_id, number);


--
-- Name: index_grader_versions_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_grader_versions_on_workspace_id_and_corpus_id_and_id ON public.grader_versions USING btree (workspace_id, corpus_id, id);


--
-- Name: index_graders_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_graders_on_workspace_id_and_corpus_id_and_id ON public.graders USING btree (workspace_id, corpus_id, id);


--
-- Name: index_human_labels_on_labelled_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_human_labels_on_labelled_by_id ON public.human_labels USING btree (labelled_by_id);


--
-- Name: index_installation_states_on_singleton; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_installation_states_on_singleton ON public.installation_states USING btree (singleton);


--
-- Name: index_issue_clusters_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_issue_clusters_on_workspace_id_and_corpus_id_and_id ON public.issue_clusters USING btree (workspace_id, corpus_id, id);


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
-- Name: index_oidc_identities_on_issuer_and_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_oidc_identities_on_issuer_and_subject ON public.oidc_identities USING btree (issuer, subject);


--
-- Name: index_oidc_identities_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_oidc_identities_on_user_id ON public.oidc_identities USING btree (user_id);


--
-- Name: index_organizations_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_organizations_on_slug ON public.organizations USING btree (slug);


--
-- Name: index_pending_workspace_invitations_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_pending_workspace_invitations_on_email ON public.workspace_invitations USING btree (workspace_id, lower((email_address)::text)) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_scenario_reviews_on_reviewed_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_scenario_reviews_on_reviewed_by_id ON public.scenario_reviews USING btree (reviewed_by_id);


--
-- Name: index_scenario_reviews_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_scenario_reviews_on_workspace_id_and_corpus_id_and_id ON public.scenario_reviews USING btree (workspace_id, corpus_id, id);


--
-- Name: index_scenario_versions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_scenario_versions_on_created_by_id ON public.scenario_versions USING btree (created_by_id);


--
-- Name: index_scenario_versions_on_scenario_id_and_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_scenario_versions_on_scenario_id_and_number ON public.scenario_versions USING btree (scenario_id, number);


--
-- Name: index_scenario_versions_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_scenario_versions_on_workspace_id_and_corpus_id_and_id ON public.scenario_versions USING btree (workspace_id, corpus_id, id);


--
-- Name: index_scenarios_on_cluster_member_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_scenarios_on_cluster_member_id ON public.scenarios USING btree (cluster_member_id);


--
-- Name: index_scenarios_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_scenarios_on_workspace_id_and_corpus_id_and_id ON public.scenarios USING btree (workspace_id, corpus_id, id);


--
-- Name: index_sessions_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_expires_at ON public.sessions USING btree (expires_at);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_source_snapshots_on_imported_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_source_snapshots_on_imported_by_id ON public.source_snapshots USING btree (imported_by_id);


--
-- Name: index_source_snapshots_on_source_id_and_digest_and_redaction; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_source_snapshots_on_source_id_and_digest_and_redaction ON public.source_snapshots USING btree (source_id, digest, redaction);


--
-- Name: index_source_snapshots_on_source_id_and_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_source_snapshots_on_source_id_and_number ON public.source_snapshots USING btree (source_id, number);


--
-- Name: index_source_snapshots_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_source_snapshots_on_workspace_id_and_corpus_id_and_id ON public.source_snapshots USING btree (workspace_id, corpus_id, id);


--
-- Name: index_source_snapshots_on_workspace_id_and_source_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_source_snapshots_on_workspace_id_and_source_id_and_id ON public.source_snapshots USING btree (workspace_id, source_id, id);


--
-- Name: index_sources_on_corpus_id_and_name_and_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sources_on_corpus_id_and_name_and_kind ON public.sources USING btree (corpus_id, name, kind);


--
-- Name: index_sources_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sources_on_workspace_id_and_corpus_id_and_id ON public.sources USING btree (workspace_id, corpus_id, id);


--
-- Name: index_taxonomy_versions_on_corpus_analysis_id_and_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_taxonomy_versions_on_corpus_analysis_id_and_number ON public.taxonomy_versions USING btree (corpus_analysis_id, number);


--
-- Name: index_taxonomy_versions_on_reviewed_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taxonomy_versions_on_reviewed_by_id ON public.taxonomy_versions USING btree (reviewed_by_id);


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
-- Name: calibration_predictions calibration_predictions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER calibration_predictions_immutable BEFORE UPDATE ON public.calibration_predictions FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: calibration_samples calibration_samples_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER calibration_samples_immutable BEFORE UPDATE ON public.calibration_samples FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: calibration_sets calibration_sets_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER calibration_sets_immutable BEFORE UPDATE ON public.calibration_sets FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: cluster_members cluster_members_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cluster_members_immutable BEFORE UPDATE ON public.cluster_members FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: corpus_analysis_inputs corpus_analysis_inputs_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER corpus_analysis_inputs_immutable BEFORE UPDATE ON public.corpus_analysis_inputs FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: corpus_items corpus_items_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER corpus_items_immutable BEFORE UPDATE ON public.corpus_items FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: eval_case_checks eval_case_checks_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER eval_case_checks_immutable BEFORE UPDATE ON public.eval_case_checks FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: eval_cases eval_cases_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER eval_cases_immutable BEFORE UPDATE ON public.eval_cases FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: grader_versions grader_versions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER grader_versions_immutable BEFORE UPDATE ON public.grader_versions FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: human_labels human_labels_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER human_labels_immutable BEFORE UPDATE ON public.human_labels FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: issue_clusters issue_clusters_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER issue_clusters_immutable BEFORE UPDATE ON public.issue_clusters FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: scenario_evidence scenario_evidence_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER scenario_evidence_immutable BEFORE UPDATE ON public.scenario_evidence FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: scenario_reviews scenario_reviews_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER scenario_reviews_immutable BEFORE UPDATE ON public.scenario_reviews FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: scenario_versions scenario_versions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER scenario_versions_immutable BEFORE UPDATE ON public.scenario_versions FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: source_snapshots source_snapshots_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER source_snapshots_immutable BEFORE UPDATE ON public.source_snapshots FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: taxonomy_versions taxonomy_versions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER taxonomy_versions_immutable BEFORE UPDATE ON public.taxonomy_versions FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: calibration_sets fk_rails_03578f8e6c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_sets
    ADD CONSTRAINT fk_rails_03578f8e6c FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: taxonomy_versions fk_rails_099165acfd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taxonomy_versions
    ADD CONSTRAINT fk_rails_099165acfd FOREIGN KEY (workspace_id, corpus_id, corpus_analysis_id) REFERENCES public.corpus_analyses(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: calibration_samples fk_rails_0ec147bff8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_samples
    ADD CONSTRAINT fk_rails_0ec147bff8 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: taxonomy_versions fk_rails_268a492cb1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taxonomy_versions
    ADD CONSTRAINT fk_rails_268a492cb1 FOREIGN KEY (reviewed_by_id) REFERENCES public.users(id);


--
-- Name: cluster_members fk_rails_2db3654de9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cluster_members
    ADD CONSTRAINT fk_rails_2db3654de9 FOREIGN KEY (workspace_id, corpus_id, corpus_item_id) REFERENCES public.corpus_items(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: eval_suite_cases fk_rails_316c8d5559; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_suite_cases
    ADD CONSTRAINT fk_rails_316c8d5559 FOREIGN KEY (workspace_id, corpus_id, eval_case_id) REFERENCES public.eval_cases(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: source_snapshots fk_rails_31de20a847; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_snapshots
    ADD CONSTRAINT fk_rails_31de20a847 FOREIGN KEY (workspace_id, corpus_id, source_id) REFERENCES public.sources(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: scenario_reviews fk_rails_3401605e5c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_reviews
    ADD CONSTRAINT fk_rails_3401605e5c FOREIGN KEY (reviewed_by_id) REFERENCES public.users(id);


--
-- Name: workspaces fk_rails_3e6d59991e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT fk_rails_3e6d59991e FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: human_labels fk_rails_3e83bdefb2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.human_labels
    ADD CONSTRAINT fk_rails_3e83bdefb2 FOREIGN KEY (workspace_id, corpus_id, calibration_sample_id) REFERENCES public.calibration_samples(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: eval_case_checks fk_rails_41d1dcba7f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_case_checks
    ADD CONSTRAINT fk_rails_41d1dcba7f FOREIGN KEY (workspace_id, corpus_id, grader_version_id) REFERENCES public.grader_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: scenario_reviews fk_rails_4c0ea7fdf9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_reviews
    ADD CONSTRAINT fk_rails_4c0ea7fdf9 FOREIGN KEY (workspace_id, corpus_id, scenario_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: scenario_evidence fk_rails_4d2df96de0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_evidence
    ADD CONSTRAINT fk_rails_4d2df96de0 FOREIGN KEY (workspace_id, corpus_id, scenario_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: eval_case_checks fk_rails_57be130586; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_case_checks
    ADD CONSTRAINT fk_rails_57be130586 FOREIGN KEY (workspace_id, corpus_id, scenario_version_id, scenario_evidence_id) REFERENCES public.scenario_evidence(workspace_id, corpus_id, scenario_version_id, id) ON DELETE CASCADE;


--
-- Name: corpus_analysis_inputs fk_rails_5940e5b0b1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analysis_inputs
    ADD CONSTRAINT fk_rails_5940e5b0b1 FOREIGN KEY (workspace_id, corpus_id, corpus_analysis_id) REFERENCES public.corpus_analyses(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: corpus_analyses fk_rails_5ea0a55698; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analyses
    ADD CONSTRAINT fk_rails_5ea0a55698 FOREIGN KEY (workspace_id, corpus_id) REFERENCES public.corpora(workspace_id, id) ON DELETE CASCADE;


--
-- Name: scenario_versions fk_rails_5ea6b98ad3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_versions
    ADD CONSTRAINT fk_rails_5ea6b98ad3 FOREIGN KEY (workspace_id, corpus_id, scenario_id) REFERENCES public.scenarios(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: workspace_invitations fk_rails_627a78e220; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations
    ADD CONSTRAINT fk_rails_627a78e220 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: eval_cases fk_rails_6d522a3523; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_cases
    ADD CONSTRAINT fk_rails_6d522a3523 FOREIGN KEY (workspace_id, corpus_id, scenario_version_id, scenario_review_id) REFERENCES public.scenario_reviews(workspace_id, corpus_id, scenario_version_id, id) ON DELETE CASCADE;


--
-- Name: calibration_predictions fk_rails_73dcb2bb89; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_predictions
    ADD CONSTRAINT fk_rails_73dcb2bb89 FOREIGN KEY (workspace_id, corpus_id, calibration_sample_id) REFERENCES public.calibration_samples(workspace_id, corpus_id, id) ON DELETE CASCADE;


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
-- Name: sources fk_rails_7832bc1c85; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT fk_rails_7832bc1c85 FOREIGN KEY (workspace_id, id, current_snapshot_id) REFERENCES public.source_snapshots(workspace_id, source_id, id);


--
-- Name: source_snapshots fk_rails_7856a7f759; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_snapshots
    ADD CONSTRAINT fk_rails_7856a7f759 FOREIGN KEY (imported_by_id) REFERENCES public.users(id);


--
-- Name: graders fk_rails_7c963efe58; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.graders
    ADD CONSTRAINT fk_rails_7c963efe58 FOREIGN KEY (workspace_id, corpus_id, id, current_version_id) REFERENCES public.grader_versions(workspace_id, corpus_id, grader_id, id) ON DELETE CASCADE;


--
-- Name: graders fk_rails_7db31e9b3a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.graders
    ADD CONSTRAINT fk_rails_7db31e9b3a FOREIGN KEY (workspace_id, corpus_id) REFERENCES public.corpora(workspace_id, id) ON DELETE CASCADE;


--
-- Name: scenarios fk_rails_7e753102d7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenarios
    ADD CONSTRAINT fk_rails_7e753102d7 FOREIGN KEY (workspace_id, corpus_id, parent_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: issue_clusters fk_rails_8102c9b2a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_clusters
    ADD CONSTRAINT fk_rails_8102c9b2a4 FOREIGN KEY (workspace_id, corpus_id, corpus_analysis_id) REFERENCES public.corpus_analyses(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: scenarios fk_rails_8690adf9aa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenarios
    ADD CONSTRAINT fk_rails_8690adf9aa FOREIGN KEY (workspace_id, corpus_id, corpus_item_id) REFERENCES public.corpus_items(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: scenario_evidence fk_rails_892abb13cb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_evidence
    ADD CONSTRAINT fk_rails_892abb13cb FOREIGN KEY (workspace_id, corpus_id, corpus_item_id) REFERENCES public.corpus_items(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: calibration_sets fk_rails_93f1ed4933; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_sets
    ADD CONSTRAINT fk_rails_93f1ed4933 FOREIGN KEY (workspace_id, corpus_id, grader_version_id) REFERENCES public.grader_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: scenarios fk_rails_954ce30522; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenarios
    ADD CONSTRAINT fk_rails_954ce30522 FOREIGN KEY (workspace_id, corpus_id, merged_into_id) REFERENCES public.scenarios(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: eval_suite_cases fk_rails_9780aeb9cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_suite_cases
    ADD CONSTRAINT fk_rails_9780aeb9cf FOREIGN KEY (workspace_id, corpus_id, eval_suite_id) REFERENCES public.eval_suites(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: memberships fk_rails_99326fb65d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_99326fb65d FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: corpus_items fk_rails_a030d050b9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_items
    ADD CONSTRAINT fk_rails_a030d050b9 FOREIGN KEY (workspace_id, corpus_id, source_snapshot_id) REFERENCES public.source_snapshots(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: cluster_members fk_rails_a10aa346f5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cluster_members
    ADD CONSTRAINT fk_rails_a10aa346f5 FOREIGN KEY (workspace_id, corpus_id, issue_cluster_id) REFERENCES public.issue_clusters(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: scenarios fk_rails_a36063d5b6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenarios
    ADD CONSTRAINT fk_rails_a36063d5b6 FOREIGN KEY (workspace_id, corpus_id, id, current_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, scenario_id, id) ON DELETE CASCADE;


--
-- Name: calibration_samples fk_rails_a4968599f3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_samples
    ADD CONSTRAINT fk_rails_a4968599f3 FOREIGN KEY (workspace_id, corpus_id, eval_case_check_id, grader_version_id) REFERENCES public.eval_case_checks(workspace_id, corpus_id, id, grader_version_id) ON DELETE CASCADE;


--
-- Name: corpora fk_rails_a618c606d9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpora
    ADD CONSTRAINT fk_rails_a618c606d9 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: workspace_invitations fk_rails_aa0ff4982f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations
    ADD CONSTRAINT fk_rails_aa0ff4982f FOREIGN KEY (accepted_by_id) REFERENCES public.users(id);


--
-- Name: sources fk_rails_af1ed8e28f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT fk_rails_af1ed8e28f FOREIGN KEY (workspace_id, corpus_id) REFERENCES public.corpora(workspace_id, id) ON DELETE CASCADE;


--
-- Name: grader_versions fk_rails_afa015c295; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grader_versions
    ADD CONSTRAINT fk_rails_afa015c295 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: human_labels fk_rails_c25eaef411; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.human_labels
    ADD CONSTRAINT fk_rails_c25eaef411 FOREIGN KEY (labelled_by_id) REFERENCES public.users(id);


--
-- Name: audit_events fk_rails_cdb00c0cbd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_cdb00c0cbd FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: eval_suites fk_rails_d24ea6f10a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_suites
    ADD CONSTRAINT fk_rails_d24ea6f10a FOREIGN KEY (workspace_id, corpus_id) REFERENCES public.corpora(workspace_id, id) ON DELETE CASCADE;


--
-- Name: eval_cases fk_rails_d48950e1f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_cases
    ADD CONSTRAINT fk_rails_d48950e1f0 FOREIGN KEY (compiled_by_id) REFERENCES public.users(id);


--
-- Name: scenario_versions fk_rails_d833017fc5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_versions
    ADD CONSTRAINT fk_rails_d833017fc5 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: scenarios fk_rails_db9ebf41f5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenarios
    ADD CONSTRAINT fk_rails_db9ebf41f5 FOREIGN KEY (workspace_id, corpus_id, cluster_member_id) REFERENCES public.cluster_members(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: audit_events fk_rails_dd1f3a471a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_dd1f3a471a FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: eval_cases fk_rails_e02fd1ea6b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_cases
    ADD CONSTRAINT fk_rails_e02fd1ea6b FOREIGN KEY (workspace_id, corpus_id, scenario_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: memberships fk_rails_e7b442f67c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_e7b442f67c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: corpus_analyses fk_rails_ed547a04e8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analyses
    ADD CONSTRAINT fk_rails_ed547a04e8 FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


--
-- Name: scenario_reviews fk_rails_ee35479abf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_reviews
    ADD CONSTRAINT fk_rails_ee35479abf FOREIGN KEY (workspace_id, corpus_id, merged_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: calibration_samples fk_rails_f5bc28b28d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_samples
    ADD CONSTRAINT fk_rails_f5bc28b28d FOREIGN KEY (workspace_id, corpus_id, calibration_set_id, grader_version_id) REFERENCES public.calibration_sets(workspace_id, corpus_id, id, grader_version_id) ON DELETE CASCADE;


--
-- Name: eval_case_checks fk_rails_f6f209f707; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_case_checks
    ADD CONSTRAINT fk_rails_f6f209f707 FOREIGN KEY (workspace_id, corpus_id, eval_case_id, scenario_version_id) REFERENCES public.eval_cases(workspace_id, corpus_id, id, scenario_version_id) ON DELETE CASCADE;


--
-- Name: oidc_identities fk_rails_f976bdec82; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_identities
    ADD CONSTRAINT fk_rails_f976bdec82 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: corpus_analysis_inputs fk_rails_fc77184e40; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analysis_inputs
    ADD CONSTRAINT fk_rails_fc77184e40 FOREIGN KEY (workspace_id, corpus_id, corpus_item_id) REFERENCES public.corpus_items(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: grader_versions fk_rails_ffcbfb4ead; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grader_versions
    ADD CONSTRAINT fk_rails_ffcbfb4ead FOREIGN KEY (workspace_id, corpus_id, grader_id) REFERENCES public.graders(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260930050000'),
('20260930040000'),
('20260930030000'),
('20260930020000'),
('20260930010000'),
('20260824230700'),
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
('20260823195257');

