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
-- Name: check_assumption_impact_input(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_assumption_impact_input() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM assumption_impacts a,
    jsonb_array_elements(a.input->'scenarios') s
    WHERE a.id = NEW.assumption_impact_id AND a.state = 'queued'
      AND s->>'version_id' = NEW.scenario_version_id::text) THEN
    RAISE EXCEPTION 'change analysis input must be a disclosed fixed version before claim';
  END IF;
  RETURN NEW;
END; $$;


--
-- Name: check_assumption_impact_result(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_assumption_impact_result() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM assumption_impacts
    WHERE id = NEW.assumption_impact_id AND state = 'running') THEN
    RAISE EXCEPTION 'change analysis result requires a claimed running attempt';
  END IF;
  RETURN NEW;
END; $$;


--
-- Name: prevent_assumption_impact_rewrite(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_assumption_impact_rewrite() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.state <> 'queued' THEN
      RAISE EXCEPTION 'change analysis must start with an unclaimed queued attempt';
    END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - ARRAY['state','error','started_at','finished_at'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['state','error','started_at','finished_at'])
    OR OLD.state IN ('complete','interrupted')
    OR (OLD.state = 'queued' AND NEW.state NOT IN ('running','interrupted'))
    OR (OLD.state = 'running' AND (NEW.state NOT IN ('complete','interrupted') OR NEW.started_at IS DISTINCT FROM OLD.started_at)) THEN
    RAISE EXCEPTION 'change analysis definition, claim and terminal receipt are immutable';
  END IF;
  IF NEW.state = 'complete' AND NOT EXISTS (
    SELECT 1 FROM assumption_impact_results WHERE assumption_impact_id = NEW.id) THEN
    RAISE EXCEPTION 'complete change analysis requires its immutable result';
  END IF;
  RETURN NEW;
END; $$;


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
-- Name: prevent_corpus_analysis_rewrite(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_corpus_analysis_rewrite() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (to_jsonb(NEW) - ARRAY['state', 'summary', 'error', 'started_at', 'finished_at', 'updated_at'])
     IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['state', 'summary', 'error', 'started_at', 'finished_at', 'updated_at'])
     OR (OLD.state IN ('complete', 'failed') AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD)) THEN
    RAISE EXCEPTION 'corpus analysis definition and terminal result are immutable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: prevent_corpus_batch_rewrite(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_corpus_batch_rewrite() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (to_jsonb(NEW) - ARRAY['state', 'result', 'started_at', 'finished_at'])
     IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['state', 'result', 'started_at', 'finished_at'])
     OR (OLD.state IN ('proposal', 'abstain', 'error') AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD))
     OR (OLD.state = 'running' AND NEW.state NOT IN ('proposal', 'abstain', 'error'))
     OR (OLD.state = 'running' AND NEW.started_at IS DISTINCT FROM OLD.started_at)
     OR (OLD.state = 'queued' AND NEW.state <> 'running') THEN
    RAISE EXCEPTION 'batch definition, claim and terminal receipt are immutable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: prevent_evaluation_run_rebind(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_evaluation_run_rebind() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (to_jsonb(NEW) - ARRAY['state', 'error', 'started_at', 'finished_at'])
     IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['state', 'error', 'started_at', 'finished_at']) THEN
    RAISE EXCEPTION 'evaluation run definition is immutable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: prevent_lab_version_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_lab_version_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION 'lab versions are immutable'; END; $$;


--
-- Name: purge_model_matching_copy(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.purge_model_matching_copy() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  DELETE FROM model_failure_matchings WHERE id = OLD.model_failure_matching_id;
  RETURN OLD;
END;
$$;


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
-- Name: assumption_impact_inputs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assumption_impact_inputs (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    assumption_impact_id bigint NOT NULL,
    scenario_version_id bigint NOT NULL
);


--
-- Name: assumption_impact_inputs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.assumption_impact_inputs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: assumption_impact_inputs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.assumption_impact_inputs_id_seq OWNED BY public.assumption_impact_inputs.id;


--
-- Name: assumption_impact_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assumption_impact_results (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    assumption_impact_id bigint NOT NULL,
    result jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_1e5d699980 CHECK (((jsonb_typeof(result) = 'object'::text) AND (result ? 'decision'::text) AND ((result ->> 'decision'::text) = ANY (ARRAY['proposal'::text, 'abstain'::text, 'error'::text]))))
);


--
-- Name: assumption_impact_results_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.assumption_impact_results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: assumption_impact_results_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.assumption_impact_results_id_seq OWNED BY public.assumption_impact_results.id;


--
-- Name: assumption_impacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assumption_impacts (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    source_id bigint NOT NULL,
    before_snapshot_id bigint NOT NULL,
    after_snapshot_id bigint NOT NULL,
    source_head_id bigint NOT NULL,
    requested_by_id bigint NOT NULL,
    historical boolean NOT NULL,
    input jsonb NOT NULL,
    input_digest character varying NOT NULL,
    configuration jsonb NOT NULL,
    request_digest character varying NOT NULL,
    processing_version character varying NOT NULL,
    request_key uuid DEFAULT gen_random_uuid() NOT NULL,
    state character varying DEFAULT 'queued'::character varying NOT NULL,
    error text,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT assumption_impact_claim_state CHECK (((((state)::text = 'queued'::text) AND (started_at IS NULL) AND (finished_at IS NULL) AND (error IS NULL)) OR (((state)::text = 'running'::text) AND (started_at IS NOT NULL) AND (finished_at IS NULL) AND (error IS NULL)) OR (((state)::text = 'complete'::text) AND (started_at IS NOT NULL) AND (finished_at IS NOT NULL) AND (error IS NULL)) OR (((state)::text = 'interrupted'::text) AND (finished_at IS NOT NULL) AND (error IS NOT NULL)))),
    CONSTRAINT chk_rails_555d6f7666 CHECK (((before_snapshot_id <> after_snapshot_id) AND (historical = (after_snapshot_id <> source_head_id)) AND (jsonb_typeof(input) = 'object'::text) AND (jsonb_typeof(configuration) = 'object'::text) AND ((input_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((request_digest)::text ~ '^[0-9a-f]{64}$'::text)))
);


--
-- Name: assumption_impacts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.assumption_impacts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: assumption_impacts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.assumption_impacts_id_seq OWNED BY public.assumption_impacts.id;


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
-- Name: calibration_judge_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calibration_judge_runs (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    calibration_sample_id bigint NOT NULL,
    requested_by_id bigint NOT NULL,
    request_key uuid DEFAULT gen_random_uuid() NOT NULL,
    state character varying DEFAULT 'queued'::character varying NOT NULL,
    error text,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_f2c1efb45c CHECK (((state)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text, ('complete'::character varying)::text, ('interrupted'::character varying)::text])))
);


--
-- Name: calibration_judge_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calibration_judge_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calibration_judge_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calibration_judge_runs_id_seq OWNED BY public.calibration_judge_runs.id;


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
    eval_case_id bigint NOT NULL,
    evaluation_result_id bigint,
    CONSTRAINT chk_rails_223ca5464b CHECK ((((cohort)::text = ANY (ARRAY[('development'::character varying)::text, ('held_out'::character varying)::text])) AND (jsonb_typeof(output) = 'object'::text)))
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
    created_at timestamp(6) without time zone NOT NULL,
    false_positive_cost numeric,
    false_negative_cost numeric,
    error_cost_unit text,
    error_cost_rationale text,
    CONSTRAINT calibration_error_cost_group CHECK ((((false_positive_cost IS NULL) AND (false_negative_cost IS NULL) AND (error_cost_unit IS NULL) AND (error_cost_rationale IS NULL)) OR ((false_positive_cost IS NOT NULL) AND (false_negative_cost IS NOT NULL) AND (error_cost_unit IS NOT NULL) AND (error_cost_rationale IS NOT NULL) AND (false_positive_cost >= (0)::numeric) AND (false_positive_cost < ('1000000000000'::bigint)::numeric) AND (false_negative_cost >= (0)::numeric) AND (false_negative_cost < ('1000000000000'::bigint)::numeric) AND (scale(false_positive_cost) <= 6) AND (scale(false_negative_cost) <= 6) AND ((char_length(error_cost_unit) >= 1) AND (char_length(error_cost_unit) <= 120)) AND (error_cost_unit ~ '[^[:space:]]'::text) AND ((char_length(error_cost_rationale) >= 1) AND (char_length(error_cost_rationale) <= 2000)) AND (error_cost_rationale ~ '[^[:space:]]'::text))))
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
    configuration jsonb DEFAULT '{}'::jsonb NOT NULL,
    input_digest character varying,
    request_key uuid DEFAULT gen_random_uuid() NOT NULL,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    call_plan jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT chk_rails_6685537a78 CHECK ((((state)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text, ('complete'::character varying)::text, ('failed'::character varying)::text])) AND ((scenario_limit >= 1) AND (scenario_limit <= 100)) AND (jsonb_typeof(configuration) = 'object'::text)))
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
-- Name: corpus_analysis_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.corpus_analysis_results (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    corpus_analysis_id bigint NOT NULL,
    result jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_79fb7728b2 CHECK (((jsonb_typeof(result) = 'object'::text) AND (result ? 'decision'::text) AND ((result ->> 'decision'::text) = ANY (ARRAY['proposal'::text, 'abstain'::text, 'error'::text]))))
);


--
-- Name: corpus_analysis_results_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.corpus_analysis_results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: corpus_analysis_results_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.corpus_analysis_results_id_seq OWNED BY public.corpus_analysis_results.id;


--
-- Name: corpus_discovery_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.corpus_discovery_batches (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    corpus_analysis_id bigint NOT NULL,
    request_key uuid DEFAULT gen_random_uuid() NOT NULL,
    phase character varying NOT NULL,
    "position" integer NOT NULL,
    input_refs jsonb NOT NULL,
    input_digest character varying NOT NULL,
    state character varying DEFAULT 'queued'::character varying NOT NULL,
    result jsonb,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_80999236e2 CHECK ((((phase)::text = ANY (ARRAY[('discovery'::character varying)::text, ('reducer'::character varying)::text])) AND (("position" >= 1) AND ("position" <= 31)) AND (jsonb_typeof(input_refs) = 'array'::text) AND ((state)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text, ('proposal'::character varying)::text, ('abstain'::character varying)::text, ('error'::character varying)::text])) AND ((result IS NULL) OR (jsonb_typeof(result) = 'object'::text)))),
    CONSTRAINT corpus_batch_receipt_matches_claim CHECK (((((state)::text = 'queued'::text) AND (started_at IS NULL) AND (finished_at IS NULL) AND (result IS NULL)) OR (((state)::text = 'running'::text) AND (started_at IS NOT NULL) AND (finished_at IS NULL) AND (result IS NULL)) OR (((state)::text = ANY (ARRAY[('proposal'::character varying)::text, ('abstain'::character varying)::text, ('error'::character varying)::text])) AND (started_at IS NOT NULL) AND (finished_at IS NOT NULL) AND (result IS NOT NULL) AND (result ? 'decision'::text) AND COALESCE(((result ->> 'decision'::text) = (state)::text), false))))
);


--
-- Name: corpus_discovery_batches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.corpus_discovery_batches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: corpus_discovery_batches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.corpus_discovery_batches_id_seq OWNED BY public.corpus_discovery_batches.id;


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
-- Name: evaluation_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evaluation_results (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    evaluation_run_item_id bigint NOT NULL,
    eval_case_id bigint NOT NULL,
    status character varying NOT NULL,
    output jsonb,
    decisions jsonb DEFAULT '[]'::jsonb NOT NULL,
    error text,
    created_at timestamp(6) without time zone NOT NULL,
    execution jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT chk_rails_5576047e12 CHECK ((jsonb_typeof(execution) = 'object'::text)),
    CONSTRAINT chk_rails_e1bb064cfc CHECK ((((status)::text = ANY (ARRAY[('pass'::character varying)::text, ('fail'::character varying)::text, ('incomplete'::character varying)::text, ('error'::character varying)::text])) AND (jsonb_typeof(decisions) = 'array'::text)))
);


--
-- Name: evaluation_results_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.evaluation_results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: evaluation_results_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.evaluation_results_id_seq OWNED BY public.evaluation_results.id;


--
-- Name: evaluation_run_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evaluation_run_items (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    evaluation_run_id bigint NOT NULL,
    eval_case_id bigint NOT NULL,
    target_input jsonb NOT NULL,
    request_key uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT chk_rails_9070c2469e CHECK ((jsonb_typeof(target_input) = 'object'::text))
);


--
-- Name: evaluation_run_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.evaluation_run_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: evaluation_run_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.evaluation_run_items_id_seq OWNED BY public.evaluation_run_items.id;


--
-- Name: evaluation_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evaluation_runs (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    eval_suite_id bigint NOT NULL,
    evaluation_target_version_id bigint NOT NULL,
    requested_by_id bigint NOT NULL,
    processing_version character varying NOT NULL,
    state character varying DEFAULT 'queued'::character varying NOT NULL,
    error text,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    judge_disclosure boolean DEFAULT false NOT NULL,
    CONSTRAINT chk_rails_306154c3a8 CHECK (((state)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text, ('complete'::character varying)::text, ('interrupted'::character varying)::text])))
);


--
-- Name: evaluation_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.evaluation_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: evaluation_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.evaluation_runs_id_seq OWNED BY public.evaluation_runs.id;


--
-- Name: evaluation_target_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evaluation_target_versions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    evaluation_target_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    number integer NOT NULL,
    adapter character varying NOT NULL,
    processing_version character varying NOT NULL,
    configuration jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    trace_item_id bigint,
    CONSTRAINT chk_rails_d846093cc8 CHECK (((((adapter)::text = 'recorded'::text) = (trace_item_id IS NOT NULL)) AND (((adapter)::text <> 'recorded'::text) OR (configuration = '{}'::jsonb)))),
    CONSTRAINT chk_rails_f7cc6dafa8 CHECK (((number > 0) AND ((adapter)::text = ANY (ARRAY[('scripted'::character varying)::text, ('http'::character varying)::text, ('recorded'::character varying)::text, ('http_conversation'::character varying)::text])) AND (jsonb_typeof(configuration) = 'object'::text)))
);


--
-- Name: evaluation_target_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.evaluation_target_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: evaluation_target_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.evaluation_target_versions_id_seq OWNED BY public.evaluation_target_versions.id;


--
-- Name: evaluation_targets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evaluation_targets (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    name character varying NOT NULL,
    current_version_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: evaluation_targets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.evaluation_targets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: evaluation_targets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.evaluation_targets_id_seq OWNED BY public.evaluation_targets.id;


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
    CONSTRAINT chk_rails_e87f64985c CHECK ((((decision)::text = ANY (ARRAY[('pass'::character varying)::text, ('fail'::character varying)::text, ('uncertain'::character varying)::text])) AND ((length(rationale) >= 1) AND (length(rationale) <= 2000))))
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
-- Name: model_failure_matching_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_failure_matching_candidates (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    model_failure_matching_id bigint NOT NULL,
    scenario_version_id bigint NOT NULL
);


--
-- Name: model_failure_matching_candidates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.model_failure_matching_candidates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: model_failure_matching_candidates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.model_failure_matching_candidates_id_seq OWNED BY public.model_failure_matching_candidates.id;


--
-- Name: model_failure_matching_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_failure_matching_results (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    model_failure_matching_id bigint NOT NULL,
    result jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT model_matching_result_decision CHECK (((jsonb_typeof(result) = 'object'::text) AND (COALESCE((result ->> 'decision'::text), ''::text) = ANY (ARRAY['suggestions'::text, 'error'::text]))))
);


--
-- Name: model_failure_matching_results_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.model_failure_matching_results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: model_failure_matching_results_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.model_failure_matching_results_id_seq OWNED BY public.model_failure_matching_results.id;


--
-- Name: model_failure_matchings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_failure_matchings (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    corpus_item_id bigint NOT NULL,
    requested_by_id bigint NOT NULL,
    configuration jsonb NOT NULL,
    input jsonb NOT NULL,
    input_digest character varying NOT NULL,
    processing_version character varying NOT NULL,
    request_key uuid DEFAULT gen_random_uuid() NOT NULL,
    state character varying DEFAULT 'queued'::character varying NOT NULL,
    error text,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_4970aac3ac CHECK ((((state)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text, ('complete'::character varying)::text, ('interrupted'::character varying)::text])) AND (jsonb_typeof(configuration) = 'object'::text) AND (jsonb_typeof(input) = 'object'::text) AND ((input_digest)::text ~ '^[0-9a-f]{64}$'::text)))
);


--
-- Name: model_failure_matchings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.model_failure_matchings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: model_failure_matchings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.model_failure_matchings_id_seq OWNED BY public.model_failure_matchings.id;


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
-- Name: regression_cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.regression_cases (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    eval_suite_id bigint NOT NULL,
    eval_case_id bigint NOT NULL,
    evaluation_result_id bigint NOT NULL,
    reviewed_by_id bigint NOT NULL,
    rationale text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_327f2bc2ad CHECK (((length(rationale) >= 1) AND (length(rationale) <= 2000)))
);


--
-- Name: regression_cases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.regression_cases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: regression_cases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.regression_cases_id_seq OWNED BY public.regression_cases.id;


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
-- Name: scenario_proposal_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scenario_proposal_results (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    scenario_proposal_id bigint NOT NULL,
    result jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_3f82085132 CHECK (((jsonb_typeof(result) = 'object'::text) AND (result ? 'decision'::text) AND ((result ->> 'decision'::text) = ANY (ARRAY['proposal'::text, 'abstain'::text, 'error'::text]))))
);


--
-- Name: scenario_proposal_results_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.scenario_proposal_results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scenario_proposal_results_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.scenario_proposal_results_id_seq OWNED BY public.scenario_proposal_results.id;


--
-- Name: scenario_proposals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scenario_proposals (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    scenario_version_id bigint NOT NULL,
    requested_by_id bigint NOT NULL,
    configuration jsonb NOT NULL,
    input jsonb NOT NULL,
    processing_version character varying NOT NULL,
    request_key uuid DEFAULT gen_random_uuid() NOT NULL,
    state character varying DEFAULT 'queued'::character varying NOT NULL,
    error text,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_fccaa58882 CHECK ((((state)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text, ('complete'::character varying)::text, ('interrupted'::character varying)::text])) AND (jsonb_typeof(configuration) = 'object'::text) AND (jsonb_typeof(input) = 'object'::text)))
);


--
-- Name: scenario_proposals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.scenario_proposals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scenario_proposals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.scenario_proposals_id_seq OWNED BY public.scenario_proposals.id;


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
    follow_ups jsonb DEFAULT '[]'::jsonb NOT NULL,
    draft_notes jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT chk_rails_4d6bffc7f8 CHECK (((number > 0) AND ((origin)::text = ANY (ARRAY[('mined'::character varying)::text, ('expert'::character varying)::text, ('variant'::character varying)::text])) AND ((importance)::text = ANY (ARRAY[('normal'::character varying)::text, ('high'::character varying)::text, ('critical'::character varying)::text])) AND (jsonb_typeof(known_facts) = 'object'::text) AND (jsonb_typeof(hidden_facts) = 'object'::text) AND (jsonb_typeof(requirements) = 'object'::text))),
    CONSTRAINT chk_rails_995910e18a CHECK (((jsonb_typeof(follow_ups) = 'array'::text) AND (jsonb_array_length(follow_ups) <= 10))),
    CONSTRAINT scenario_draft_notes_bounded CHECK (((jsonb_typeof(draft_notes) = 'object'::text) AND (octet_length((draft_notes)::text) <= 10240)))
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
    mask_digest character varying DEFAULT '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945'::character varying NOT NULL,
    mask_count integer DEFAULT 0 NOT NULL,
    CONSTRAINT chk_rails_75987cdd84 CHECK (((number > 0) AND ((digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((redaction)::text = ANY (ARRAY[('email'::character varying)::text, ('none'::character varying)::text, ('exact'::character varying)::text])))),
    CONSTRAINT source_snapshot_mask_policy CHECK ((((mask_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((((redaction)::text = 'exact'::text) AND ((mask_count >= 1) AND (mask_count <= 50)) AND ((mask_digest)::text <> '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945'::text)) OR (((redaction)::text = ANY (ARRAY[('email'::character varying)::text, ('none'::character varying)::text])) AND (mask_count = 0) AND ((mask_digest)::text = '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945'::text)))))
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
    CONSTRAINT chk_rails_23967a9de0 CHECK (((kind)::text = ANY (ARRAY[('conversations'::character varying)::text, ('document'::character varying)::text, ('traces'::character varying)::text])))
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
-- Name: trace_scenario_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trace_scenario_decisions (
    id bigint NOT NULL,
    workspace_id bigint NOT NULL,
    corpus_id bigint NOT NULL,
    corpus_item_id bigint NOT NULL,
    scenario_version_id bigint NOT NULL,
    reviewed_by_id bigint NOT NULL,
    decision character varying NOT NULL,
    reason text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_rails_a0c71cf02f CHECK ((((decision)::text = ANY (ARRAY[('match'::character varying)::text, ('different'::character varying)::text, ('uncertain'::character varying)::text])) AND ((length(btrim(reason)) >= 1) AND (length(btrim(reason)) <= 2000))))
);


--
-- Name: trace_scenario_decisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.trace_scenario_decisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: trace_scenario_decisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.trace_scenario_decisions_id_seq OWNED BY public.trace_scenario_decisions.id;


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
-- Name: assumption_impact_inputs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impact_inputs ALTER COLUMN id SET DEFAULT nextval('public.assumption_impact_inputs_id_seq'::regclass);


--
-- Name: assumption_impact_results id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impact_results ALTER COLUMN id SET DEFAULT nextval('public.assumption_impact_results_id_seq'::regclass);


--
-- Name: assumption_impacts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impacts ALTER COLUMN id SET DEFAULT nextval('public.assumption_impacts_id_seq'::regclass);


--
-- Name: audit_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ALTER COLUMN id SET DEFAULT nextval('public.audit_events_id_seq'::regclass);


--
-- Name: calibration_judge_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_judge_runs ALTER COLUMN id SET DEFAULT nextval('public.calibration_judge_runs_id_seq'::regclass);


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
-- Name: corpus_analysis_results id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analysis_results ALTER COLUMN id SET DEFAULT nextval('public.corpus_analysis_results_id_seq'::regclass);


--
-- Name: corpus_discovery_batches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_discovery_batches ALTER COLUMN id SET DEFAULT nextval('public.corpus_discovery_batches_id_seq'::regclass);


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
-- Name: evaluation_results id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_results ALTER COLUMN id SET DEFAULT nextval('public.evaluation_results_id_seq'::regclass);


--
-- Name: evaluation_run_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_run_items ALTER COLUMN id SET DEFAULT nextval('public.evaluation_run_items_id_seq'::regclass);


--
-- Name: evaluation_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_runs ALTER COLUMN id SET DEFAULT nextval('public.evaluation_runs_id_seq'::regclass);


--
-- Name: evaluation_target_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_target_versions ALTER COLUMN id SET DEFAULT nextval('public.evaluation_target_versions_id_seq'::regclass);


--
-- Name: evaluation_targets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_targets ALTER COLUMN id SET DEFAULT nextval('public.evaluation_targets_id_seq'::regclass);


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
-- Name: model_failure_matching_candidates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matching_candidates ALTER COLUMN id SET DEFAULT nextval('public.model_failure_matching_candidates_id_seq'::regclass);


--
-- Name: model_failure_matching_results id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matching_results ALTER COLUMN id SET DEFAULT nextval('public.model_failure_matching_results_id_seq'::regclass);


--
-- Name: model_failure_matchings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matchings ALTER COLUMN id SET DEFAULT nextval('public.model_failure_matchings_id_seq'::regclass);


--
-- Name: oidc_identities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_identities ALTER COLUMN id SET DEFAULT nextval('public.oidc_identities_id_seq'::regclass);


--
-- Name: organizations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations ALTER COLUMN id SET DEFAULT nextval('public.organizations_id_seq'::regclass);


--
-- Name: regression_cases id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regression_cases ALTER COLUMN id SET DEFAULT nextval('public.regression_cases_id_seq'::regclass);


--
-- Name: scenario_evidence id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_evidence ALTER COLUMN id SET DEFAULT nextval('public.scenario_evidence_id_seq'::regclass);


--
-- Name: scenario_proposal_results id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_proposal_results ALTER COLUMN id SET DEFAULT nextval('public.scenario_proposal_results_id_seq'::regclass);


--
-- Name: scenario_proposals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_proposals ALTER COLUMN id SET DEFAULT nextval('public.scenario_proposals_id_seq'::regclass);


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
-- Name: trace_scenario_decisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trace_scenario_decisions ALTER COLUMN id SET DEFAULT nextval('public.trace_scenario_decisions_id_seq'::regclass);


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
-- Name: assumption_impact_inputs assumption_impact_inputs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impact_inputs
    ADD CONSTRAINT assumption_impact_inputs_pkey PRIMARY KEY (id);


--
-- Name: assumption_impact_results assumption_impact_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impact_results
    ADD CONSTRAINT assumption_impact_results_pkey PRIMARY KEY (id);


--
-- Name: assumption_impacts assumption_impacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impacts
    ADD CONSTRAINT assumption_impacts_pkey PRIMARY KEY (id);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: calibration_judge_runs calibration_judge_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_judge_runs
    ADD CONSTRAINT calibration_judge_runs_pkey PRIMARY KEY (id);


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
-- Name: corpus_analysis_results corpus_analysis_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analysis_results
    ADD CONSTRAINT corpus_analysis_results_pkey PRIMARY KEY (id);


--
-- Name: corpus_discovery_batches corpus_discovery_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_discovery_batches
    ADD CONSTRAINT corpus_discovery_batches_pkey PRIMARY KEY (id);


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
-- Name: evaluation_results evaluation_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_results
    ADD CONSTRAINT evaluation_results_pkey PRIMARY KEY (id);


--
-- Name: evaluation_run_items evaluation_run_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_run_items
    ADD CONSTRAINT evaluation_run_items_pkey PRIMARY KEY (id);


--
-- Name: evaluation_runs evaluation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_runs
    ADD CONSTRAINT evaluation_runs_pkey PRIMARY KEY (id);


--
-- Name: evaluation_target_versions evaluation_target_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_target_versions
    ADD CONSTRAINT evaluation_target_versions_pkey PRIMARY KEY (id);


--
-- Name: evaluation_targets evaluation_targets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_targets
    ADD CONSTRAINT evaluation_targets_pkey PRIMARY KEY (id);


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
-- Name: model_failure_matching_candidates model_failure_matching_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matching_candidates
    ADD CONSTRAINT model_failure_matching_candidates_pkey PRIMARY KEY (id);


--
-- Name: model_failure_matching_results model_failure_matching_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matching_results
    ADD CONSTRAINT model_failure_matching_results_pkey PRIMARY KEY (id);


--
-- Name: model_failure_matchings model_failure_matchings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matchings
    ADD CONSTRAINT model_failure_matchings_pkey PRIMARY KEY (id);


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
-- Name: regression_cases regression_cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regression_cases
    ADD CONSTRAINT regression_cases_pkey PRIMARY KEY (id);


--
-- Name: scenario_evidence scenario_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_evidence
    ADD CONSTRAINT scenario_evidence_pkey PRIMARY KEY (id);


--
-- Name: scenario_proposal_results scenario_proposal_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_proposal_results
    ADD CONSTRAINT scenario_proposal_results_pkey PRIMARY KEY (id);


--
-- Name: scenario_proposals scenario_proposals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_proposals
    ADD CONSTRAINT scenario_proposals_pkey PRIMARY KEY (id);


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
-- Name: trace_scenario_decisions trace_scenario_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trace_scenario_decisions
    ADD CONSTRAINT trace_scenario_decisions_pkey PRIMARY KEY (id);


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
-- Name: calibration_check_case_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX calibration_check_case_identity ON public.eval_case_checks USING btree (workspace_id, corpus_id, id, eval_case_id);


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
-- Name: idx_on_corpus_analysis_id_position_9f8574be0c; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_corpus_analysis_id_position_9f8574be0c ON public.corpus_discovery_batches USING btree (corpus_analysis_id, "position");


--
-- Name: idx_on_eval_case_id_requirement_kind_requirement_in_8a3502f15b; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_eval_case_id_requirement_kind_requirement_in_8a3502f15b ON public.eval_case_checks USING btree (eval_case_id, requirement_kind, requirement_index);


--
-- Name: idx_on_eval_suite_id_evaluation_result_id_6f695d58f9; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_eval_suite_id_evaluation_result_id_6f695d58f9 ON public.regression_cases USING btree (eval_suite_id, evaluation_result_id);


--
-- Name: idx_on_evaluation_run_id_eval_case_id_1f97109920; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_evaluation_run_id_eval_case_id_1f97109920 ON public.evaluation_run_items USING btree (evaluation_run_id, eval_case_id);


--
-- Name: idx_on_evaluation_target_id_number_9d515c6581; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_evaluation_target_id_number_9d515c6581 ON public.evaluation_target_versions USING btree (evaluation_target_id, number);


--
-- Name: idx_on_model_failure_matching_id_80f74e3dad; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_model_failure_matching_id_80f74e3dad ON public.model_failure_matching_results USING btree (model_failure_matching_id);


--
-- Name: idx_on_scenario_version_id_corpus_item_id_kind_455675656f; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_scenario_version_id_corpus_item_id_kind_455675656f ON public.scenario_evidence USING btree (scenario_version_id, corpus_item_id, kind);


--
-- Name: idx_on_workspace_id_corpus_id_evaluation_target_id__d962945b79; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_evaluation_target_id__d962945b79 ON public.evaluation_target_versions USING btree (workspace_id, corpus_id, evaluation_target_id, id);


--
-- Name: idx_on_workspace_id_corpus_id_grader_id_id_69031213be; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_grader_id_id_69031213be ON public.grader_versions USING btree (workspace_id, corpus_id, grader_id, id);


--
-- Name: idx_on_workspace_id_corpus_id_id_64c83596d2; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_id_64c83596d2 ON public.model_failure_matchings USING btree (workspace_id, corpus_id, id);


--
-- Name: idx_on_workspace_id_corpus_id_id_a4ab285c61; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_id_a4ab285c61 ON public.evaluation_target_versions USING btree (workspace_id, corpus_id, id);


--
-- Name: idx_on_workspace_id_corpus_id_id_eval_case_id_512aa167ec; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_id_eval_case_id_512aa167ec ON public.evaluation_results USING btree (workspace_id, corpus_id, id, eval_case_id);


--
-- Name: idx_on_workspace_id_corpus_id_id_eval_case_id_d1064dd5d1; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_id_eval_case_id_d1064dd5d1 ON public.evaluation_run_items USING btree (workspace_id, corpus_id, id, eval_case_id);


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
-- Name: idx_on_workspace_id_corpus_id_source_id_id_5d6a5df986; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_corpus_id_source_id_id_5d6a5df986 ON public.source_snapshots USING btree (workspace_id, corpus_id, source_id, id);


--
-- Name: index_assumption_impact_results_on_assumption_impact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_assumption_impact_results_on_assumption_impact_id ON public.assumption_impact_results USING btree (assumption_impact_id);


--
-- Name: index_assumption_impacts_on_corpus_id_and_request_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_assumption_impacts_on_corpus_id_and_request_digest ON public.assumption_impacts USING btree (corpus_id, request_digest);


--
-- Name: index_assumption_impacts_on_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_assumption_impacts_on_request_key ON public.assumption_impacts USING btree (request_key);


--
-- Name: index_assumption_impacts_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_assumption_impacts_on_requested_by_id ON public.assumption_impacts USING btree (requested_by_id);


--
-- Name: index_assumption_impacts_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_assumption_impacts_on_workspace_id_and_corpus_id_and_id ON public.assumption_impacts USING btree (workspace_id, corpus_id, id);


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
-- Name: index_calibration_judge_runs_on_calibration_sample_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_calibration_judge_runs_on_calibration_sample_id ON public.calibration_judge_runs USING btree (calibration_sample_id);


--
-- Name: index_calibration_judge_runs_on_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_calibration_judge_runs_on_request_key ON public.calibration_judge_runs USING btree (request_key);


--
-- Name: index_calibration_judge_runs_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calibration_judge_runs_on_requested_by_id ON public.calibration_judge_runs USING btree (requested_by_id);


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
-- Name: index_corpus_analyses_on_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_corpus_analyses_on_request_key ON public.corpus_analyses USING btree (request_key);


--
-- Name: index_corpus_analyses_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_corpus_analyses_on_requested_by_id ON public.corpus_analyses USING btree (requested_by_id);


--
-- Name: index_corpus_analyses_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_corpus_analyses_on_workspace_id_and_corpus_id_and_id ON public.corpus_analyses USING btree (workspace_id, corpus_id, id);


--
-- Name: index_corpus_analysis_results_on_corpus_analysis_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_corpus_analysis_results_on_corpus_analysis_id ON public.corpus_analysis_results USING btree (corpus_analysis_id);


--
-- Name: index_corpus_discovery_batches_on_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_corpus_discovery_batches_on_request_key ON public.corpus_discovery_batches USING btree (request_key);


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
-- Name: index_evaluation_results_on_evaluation_run_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_evaluation_results_on_evaluation_run_item_id ON public.evaluation_results USING btree (evaluation_run_item_id);


--
-- Name: index_evaluation_run_items_on_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_evaluation_run_items_on_request_key ON public.evaluation_run_items USING btree (request_key);


--
-- Name: index_evaluation_runs_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_evaluation_runs_on_requested_by_id ON public.evaluation_runs USING btree (requested_by_id);


--
-- Name: index_evaluation_runs_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_evaluation_runs_on_workspace_id_and_corpus_id_and_id ON public.evaluation_runs USING btree (workspace_id, corpus_id, id);


--
-- Name: index_evaluation_target_versions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_evaluation_target_versions_on_created_by_id ON public.evaluation_target_versions USING btree (created_by_id);


--
-- Name: index_evaluation_target_versions_on_trace_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_evaluation_target_versions_on_trace_item_id ON public.evaluation_target_versions USING btree (trace_item_id);


--
-- Name: index_evaluation_targets_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_evaluation_targets_on_workspace_id_and_corpus_id_and_id ON public.evaluation_targets USING btree (workspace_id, corpus_id, id);


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
-- Name: index_model_failure_matchings_on_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_model_failure_matchings_on_request_key ON public.model_failure_matchings USING btree (request_key);


--
-- Name: index_model_failure_matchings_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_model_failure_matchings_on_requested_by_id ON public.model_failure_matchings USING btree (requested_by_id);


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
-- Name: index_regression_cases_on_reviewed_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_regression_cases_on_reviewed_by_id ON public.regression_cases USING btree (reviewed_by_id);


--
-- Name: index_scenario_proposal_results_on_scenario_proposal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_scenario_proposal_results_on_scenario_proposal_id ON public.scenario_proposal_results USING btree (scenario_proposal_id);


--
-- Name: index_scenario_proposals_on_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_scenario_proposals_on_request_key ON public.scenario_proposals USING btree (request_key);


--
-- Name: index_scenario_proposals_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_scenario_proposals_on_requested_by_id ON public.scenario_proposals USING btree (requested_by_id);


--
-- Name: index_scenario_proposals_on_scenario_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_scenario_proposals_on_scenario_version_id ON public.scenario_proposals USING btree (scenario_version_id);


--
-- Name: index_scenario_proposals_on_workspace_id_and_corpus_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_scenario_proposals_on_workspace_id_and_corpus_id_and_id ON public.scenario_proposals USING btree (workspace_id, corpus_id, id);


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
-- Name: index_source_snapshots_on_processing_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_source_snapshots_on_processing_identity ON public.source_snapshots USING btree (source_id, digest, redaction, processing_version, mask_digest);


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
-- Name: index_trace_scenario_decisions_on_reviewed_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trace_scenario_decisions_on_reviewed_by_id ON public.trace_scenario_decisions USING btree (reviewed_by_id);


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
-- Name: model_matching_fixed_candidate; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX model_matching_fixed_candidate ON public.model_failure_matching_candidates USING btree (model_failure_matching_id, scenario_version_id);


--
-- Name: model_matching_fixed_request; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX model_matching_fixed_request ON public.model_failure_matchings USING btree (corpus_item_id, input_digest, configuration);


--
-- Name: trace_decision_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX trace_decision_history ON public.trace_scenario_decisions USING btree (corpus_item_id, scenario_version_id, reviewed_by_id, id);


--
-- Name: unique_assumption_impact_input; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_assumption_impact_input ON public.assumption_impact_inputs USING btree (assumption_impact_id, scenario_version_id);


--
-- Name: assumption_impacts assumption_impact_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER assumption_impact_immutable BEFORE INSERT OR UPDATE ON public.assumption_impacts FOR EACH ROW EXECUTE FUNCTION public.prevent_assumption_impact_rewrite();


--
-- Name: assumption_impact_inputs assumption_impact_input_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER assumption_impact_input_immutable BEFORE UPDATE ON public.assumption_impact_inputs FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: assumption_impact_inputs assumption_impact_input_matches_preview; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER assumption_impact_input_matches_preview BEFORE INSERT ON public.assumption_impact_inputs FOR EACH ROW EXECUTE FUNCTION public.check_assumption_impact_input();


--
-- Name: assumption_impact_results assumption_impact_result_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER assumption_impact_result_immutable BEFORE UPDATE ON public.assumption_impact_results FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: assumption_impact_results assumption_impact_result_matches_claim; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER assumption_impact_result_matches_claim BEFORE INSERT ON public.assumption_impact_results FOR EACH ROW EXECUTE FUNCTION public.check_assumption_impact_result();


--
-- Name: audit_events audit_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_append_only BEFORE DELETE OR UPDATE ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_event_mutation();


--
-- Name: audit_events audit_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON public.audit_events FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_audit_event_mutation();


--
-- Name: calibration_judge_runs calibration_judge_run_definition_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER calibration_judge_run_definition_immutable BEFORE UPDATE ON public.calibration_judge_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_evaluation_run_rebind();


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
-- Name: corpus_analyses corpus_analysis_definition_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER corpus_analysis_definition_immutable BEFORE UPDATE ON public.corpus_analyses FOR EACH ROW EXECUTE FUNCTION public.prevent_corpus_analysis_rewrite();


--
-- Name: corpus_analysis_inputs corpus_analysis_inputs_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER corpus_analysis_inputs_immutable BEFORE UPDATE ON public.corpus_analysis_inputs FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: corpus_analysis_results corpus_analysis_result_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER corpus_analysis_result_immutable BEFORE UPDATE ON public.corpus_analysis_results FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: corpus_discovery_batches corpus_discovery_batch_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER corpus_discovery_batch_immutable BEFORE UPDATE ON public.corpus_discovery_batches FOR EACH ROW EXECUTE FUNCTION public.prevent_corpus_batch_rewrite();


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
-- Name: evaluation_results evaluation_results_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER evaluation_results_immutable BEFORE UPDATE ON public.evaluation_results FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: evaluation_runs evaluation_run_definition_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER evaluation_run_definition_immutable BEFORE UPDATE ON public.evaluation_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_evaluation_run_rebind();


--
-- Name: evaluation_run_items evaluation_run_items_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER evaluation_run_items_immutable BEFORE UPDATE ON public.evaluation_run_items FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: evaluation_target_versions evaluation_target_versions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER evaluation_target_versions_immutable BEFORE UPDATE ON public.evaluation_target_versions FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


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
-- Name: model_failure_matching_candidates model_failure_matching_candidates_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER model_failure_matching_candidates_immutable BEFORE UPDATE ON public.model_failure_matching_candidates FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: model_failure_matching_results model_failure_matching_results_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER model_failure_matching_results_immutable BEFORE UPDATE ON public.model_failure_matching_results FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: model_failure_matching_candidates model_matching_candidate_purge; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER model_matching_candidate_purge AFTER DELETE ON public.model_failure_matching_candidates FOR EACH ROW EXECUTE FUNCTION public.purge_model_matching_copy();


--
-- Name: model_failure_matchings model_matching_definition_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER model_matching_definition_immutable BEFORE UPDATE ON public.model_failure_matchings FOR EACH ROW EXECUTE FUNCTION public.prevent_evaluation_run_rebind();


--
-- Name: regression_cases regression_cases_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER regression_cases_immutable BEFORE UPDATE ON public.regression_cases FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: scenario_evidence scenario_evidence_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER scenario_evidence_immutable BEFORE UPDATE ON public.scenario_evidence FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: scenarios scenario_parent_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER scenario_parent_immutable BEFORE UPDATE OF parent_version_id ON public.scenarios FOR EACH ROW WHEN ((old.parent_version_id IS DISTINCT FROM new.parent_version_id)) EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: scenario_proposals scenario_proposal_definition_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER scenario_proposal_definition_immutable BEFORE UPDATE ON public.scenario_proposals FOR EACH ROW EXECUTE FUNCTION public.prevent_evaluation_run_rebind();


--
-- Name: scenario_proposal_results scenario_proposal_result_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER scenario_proposal_result_immutable BEFORE UPDATE ON public.scenario_proposal_results FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


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
-- Name: trace_scenario_decisions trace_scenario_decisions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trace_scenario_decisions_immutable BEFORE UPDATE ON public.trace_scenario_decisions FOR EACH ROW EXECUTE FUNCTION public.prevent_lab_version_update();


--
-- Name: calibration_samples calibration_sample_check_case; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_samples
    ADD CONSTRAINT calibration_sample_check_case FOREIGN KEY (workspace_id, corpus_id, eval_case_check_id, eval_case_id) REFERENCES public.eval_case_checks(workspace_id, corpus_id, id, eval_case_id) ON DELETE CASCADE;


--
-- Name: calibration_samples calibration_sample_result_case; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_samples
    ADD CONSTRAINT calibration_sample_result_case FOREIGN KEY (workspace_id, corpus_id, evaluation_result_id, eval_case_id) REFERENCES public.evaluation_results(workspace_id, corpus_id, id, eval_case_id) ON DELETE CASCADE;


--
-- Name: calibration_sets fk_rails_03578f8e6c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_sets
    ADD CONSTRAINT fk_rails_03578f8e6c FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: evaluation_runs fk_rails_03e98e1f22; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_runs
    ADD CONSTRAINT fk_rails_03e98e1f22 FOREIGN KEY (workspace_id, corpus_id, eval_suite_id) REFERENCES public.eval_suites(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: regression_cases fk_rails_05ccce48ad; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regression_cases
    ADD CONSTRAINT fk_rails_05ccce48ad FOREIGN KEY (workspace_id, corpus_id, eval_suite_id) REFERENCES public.eval_suites(workspace_id, corpus_id, id) ON DELETE CASCADE;


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
-- Name: model_failure_matching_candidates fk_rails_13a04666e6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matching_candidates
    ADD CONSTRAINT fk_rails_13a04666e6 FOREIGN KEY (workspace_id, corpus_id, model_failure_matching_id) REFERENCES public.model_failure_matchings(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: trace_scenario_decisions fk_rails_14082b44a9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trace_scenario_decisions
    ADD CONSTRAINT fk_rails_14082b44a9 FOREIGN KEY (workspace_id, corpus_id, corpus_item_id) REFERENCES public.corpus_items(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: evaluation_target_versions fk_rails_1a3b9e6b69; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_target_versions
    ADD CONSTRAINT fk_rails_1a3b9e6b69 FOREIGN KEY (workspace_id, corpus_id, trace_item_id) REFERENCES public.corpus_items(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: model_failure_matching_results fk_rails_1a65fc666e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matching_results
    ADD CONSTRAINT fk_rails_1a65fc666e FOREIGN KEY (workspace_id, corpus_id, model_failure_matching_id) REFERENCES public.model_failure_matchings(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: trace_scenario_decisions fk_rails_1c9db42685; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trace_scenario_decisions
    ADD CONSTRAINT fk_rails_1c9db42685 FOREIGN KEY (workspace_id, corpus_id, scenario_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


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
-- Name: evaluation_targets fk_rails_4d9b12f815; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_targets
    ADD CONSTRAINT fk_rails_4d9b12f815 FOREIGN KEY (workspace_id, corpus_id, id, current_version_id) REFERENCES public.evaluation_target_versions(workspace_id, corpus_id, evaluation_target_id, id) ON DELETE CASCADE;


--
-- Name: evaluation_run_items fk_rails_4dcbbf54ce; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_run_items
    ADD CONSTRAINT fk_rails_4dcbbf54ce FOREIGN KEY (workspace_id, corpus_id, eval_case_id) REFERENCES public.eval_cases(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: trace_scenario_decisions fk_rails_52888c45b0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trace_scenario_decisions
    ADD CONSTRAINT fk_rails_52888c45b0 FOREIGN KEY (reviewed_by_id) REFERENCES public.users(id);


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
-- Name: evaluation_target_versions fk_rails_5adcd6eb69; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_target_versions
    ADD CONSTRAINT fk_rails_5adcd6eb69 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


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
-- Name: assumption_impacts fk_rails_616c220273; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impacts
    ADD CONSTRAINT fk_rails_616c220273 FOREIGN KEY (workspace_id, corpus_id, source_id, before_snapshot_id) REFERENCES public.source_snapshots(workspace_id, corpus_id, source_id, id) ON DELETE CASCADE;


--
-- Name: workspace_invitations fk_rails_627a78e220; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_invitations
    ADD CONSTRAINT fk_rails_627a78e220 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: assumption_impacts fk_rails_6950474d2e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impacts
    ADD CONSTRAINT fk_rails_6950474d2e FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


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
-- Name: model_failure_matching_candidates fk_rails_7615a9d05a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matching_candidates
    ADD CONSTRAINT fk_rails_7615a9d05a FOREIGN KEY (workspace_id, corpus_id, scenario_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


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
-- Name: assumption_impact_results fk_rails_80524f3ee9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impact_results
    ADD CONSTRAINT fk_rails_80524f3ee9 FOREIGN KEY (workspace_id, corpus_id, assumption_impact_id) REFERENCES public.assumption_impacts(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: issue_clusters fk_rails_8102c9b2a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_clusters
    ADD CONSTRAINT fk_rails_8102c9b2a4 FOREIGN KEY (workspace_id, corpus_id, corpus_analysis_id) REFERENCES public.corpus_analyses(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: evaluation_targets fk_rails_8192e2edfb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_targets
    ADD CONSTRAINT fk_rails_8192e2edfb FOREIGN KEY (workspace_id, corpus_id) REFERENCES public.corpora(workspace_id, id) ON DELETE CASCADE;


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
-- Name: scenario_proposals fk_rails_8975f21feb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_proposals
    ADD CONSTRAINT fk_rails_8975f21feb FOREIGN KEY (workspace_id, corpus_id, scenario_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: calibration_judge_runs fk_rails_8cddf9f3e6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_judge_runs
    ADD CONSTRAINT fk_rails_8cddf9f3e6 FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


--
-- Name: assumption_impacts fk_rails_9265226575; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impacts
    ADD CONSTRAINT fk_rails_9265226575 FOREIGN KEY (workspace_id, corpus_id, source_id) REFERENCES public.sources(workspace_id, corpus_id, id) ON DELETE CASCADE;


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
-- Name: regression_cases fk_rails_9869803d3b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regression_cases
    ADD CONSTRAINT fk_rails_9869803d3b FOREIGN KEY (reviewed_by_id) REFERENCES public.users(id);


--
-- Name: memberships fk_rails_99326fb65d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_99326fb65d FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: evaluation_results fk_rails_9e3a97f7cb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_results
    ADD CONSTRAINT fk_rails_9e3a97f7cb FOREIGN KEY (workspace_id, corpus_id, evaluation_run_item_id, eval_case_id) REFERENCES public.evaluation_run_items(workspace_id, corpus_id, id, eval_case_id) ON DELETE CASCADE;


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
-- Name: corpus_discovery_batches fk_rails_a9d5efc3ba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_discovery_batches
    ADD CONSTRAINT fk_rails_a9d5efc3ba FOREIGN KEY (workspace_id, corpus_id, corpus_analysis_id) REFERENCES public.corpus_analyses(workspace_id, corpus_id, id) ON DELETE CASCADE;


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
-- Name: evaluation_run_items fk_rails_aff0dcc99c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_run_items
    ADD CONSTRAINT fk_rails_aff0dcc99c FOREIGN KEY (workspace_id, corpus_id, evaluation_run_id) REFERENCES public.evaluation_runs(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: model_failure_matchings fk_rails_b2b8747e1c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matchings
    ADD CONSTRAINT fk_rails_b2b8747e1c FOREIGN KEY (workspace_id, corpus_id, corpus_item_id) REFERENCES public.corpus_items(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: corpus_analysis_results fk_rails_b83ebff142; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.corpus_analysis_results
    ADD CONSTRAINT fk_rails_b83ebff142 FOREIGN KEY (workspace_id, corpus_id, corpus_analysis_id) REFERENCES public.corpus_analyses(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: model_failure_matchings fk_rails_b9a604262e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_failure_matchings
    ADD CONSTRAINT fk_rails_b9a604262e FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


--
-- Name: human_labels fk_rails_c25eaef411; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.human_labels
    ADD CONSTRAINT fk_rails_c25eaef411 FOREIGN KEY (labelled_by_id) REFERENCES public.users(id);


--
-- Name: calibration_judge_runs fk_rails_cab07db990; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_judge_runs
    ADD CONSTRAINT fk_rails_cab07db990 FOREIGN KEY (workspace_id, corpus_id, calibration_sample_id) REFERENCES public.calibration_samples(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: audit_events fk_rails_cdb00c0cbd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_cdb00c0cbd FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: evaluation_target_versions fk_rails_cf312dcb8e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_target_versions
    ADD CONSTRAINT fk_rails_cf312dcb8e FOREIGN KEY (workspace_id, corpus_id, evaluation_target_id) REFERENCES public.evaluation_targets(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: eval_suites fk_rails_d24ea6f10a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_suites
    ADD CONSTRAINT fk_rails_d24ea6f10a FOREIGN KEY (workspace_id, corpus_id) REFERENCES public.corpora(workspace_id, id) ON DELETE CASCADE;


--
-- Name: assumption_impacts fk_rails_d31835cb6c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impacts
    ADD CONSTRAINT fk_rails_d31835cb6c FOREIGN KEY (workspace_id, corpus_id, source_id, after_snapshot_id) REFERENCES public.source_snapshots(workspace_id, corpus_id, source_id, id) ON DELETE CASCADE;


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
-- Name: assumption_impact_inputs fk_rails_dbe00f18b8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impact_inputs
    ADD CONSTRAINT fk_rails_dbe00f18b8 FOREIGN KEY (workspace_id, corpus_id, assumption_impact_id) REFERENCES public.assumption_impacts(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: regression_cases fk_rails_dd0f089eb7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regression_cases
    ADD CONSTRAINT fk_rails_dd0f089eb7 FOREIGN KEY (workspace_id, corpus_id, evaluation_result_id, eval_case_id) REFERENCES public.evaluation_results(workspace_id, corpus_id, id, eval_case_id) ON DELETE CASCADE;


--
-- Name: audit_events fk_rails_dd1f3a471a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_dd1f3a471a FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: evaluation_runs fk_rails_df70446887; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_runs
    ADD CONSTRAINT fk_rails_df70446887 FOREIGN KEY (workspace_id, corpus_id, evaluation_target_version_id) REFERENCES public.evaluation_target_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: eval_cases fk_rails_e02fd1ea6b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_cases
    ADD CONSTRAINT fk_rails_e02fd1ea6b FOREIGN KEY (workspace_id, corpus_id, scenario_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: scenario_proposal_results fk_rails_e0ee4bff2b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_proposal_results
    ADD CONSTRAINT fk_rails_e0ee4bff2b FOREIGN KEY (workspace_id, corpus_id, scenario_proposal_id) REFERENCES public.scenario_proposals(workspace_id, corpus_id, id) ON DELETE CASCADE;


--
-- Name: memberships fk_rails_e7b442f67c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_e7b442f67c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: evaluation_runs fk_rails_e9a13729c6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evaluation_runs
    ADD CONSTRAINT fk_rails_e9a13729c6 FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


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
-- Name: scenario_proposals fk_rails_f20742ee15; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenario_proposals
    ADD CONSTRAINT fk_rails_f20742ee15 FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


--
-- Name: assumption_impacts fk_rails_f42173c24f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impacts
    ADD CONSTRAINT fk_rails_f42173c24f FOREIGN KEY (workspace_id, corpus_id, source_id, source_head_id) REFERENCES public.source_snapshots(workspace_id, corpus_id, source_id, id) ON DELETE CASCADE;


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
-- Name: assumption_impact_inputs fk_rails_f7a4785dcd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assumption_impact_inputs
    ADD CONSTRAINT fk_rails_f7a4785dcd FOREIGN KEY (workspace_id, corpus_id, scenario_version_id) REFERENCES public.scenario_versions(workspace_id, corpus_id, id) ON DELETE CASCADE;


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
('20261002010100'),
('20261001220000'),
('20261001210000'),
('20261001200000'),
('20261001150000'),
('20261001140000'),
('20261001130000'),
('20261001120000'),
('20261001040000'),
('20261001030000'),
('20261001020000'),
('20261001010000'),
('20261001000000'),
('20260930100000'),
('20260930090000'),
('20260930080000'),
('20260930070000'),
('20260930060000'),
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

