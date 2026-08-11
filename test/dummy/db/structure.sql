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
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: rs_billing_protect_candidate_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_candidate_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'commercial publication candidates are immutable';
  END IF;
  IF OLD.activated_at IS NULL AND NEW.activated_at IS NOT NULL AND
     (to_jsonb(OLD) - 'activated_at' - 'updated_at') =
       (to_jsonb(NEW) - 'activated_at' - 'updated_at') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'commercial publication candidates are immutable';
END;
$$;


--
-- Name: rs_billing_protect_commercial_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_commercial_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.state IN ('published', 'retired') OR NOT EXISTS (
    SELECT 1
    FROM recording_studio_recordings
    WHERE recordable_type = TG_ARGV[0]
      AND recordable_id = OLD.id
  ) THEN
    RAISE EXCEPTION 'published, retired, and historical commercial records are immutable';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.state = 'draft' AND NEW.state <> 'draft' THEN
    RAISE EXCEPTION 'commercial publication must create an authorized revision';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: rs_billing_protect_manifest_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_manifest_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'commercial manifests are immutable';
  END IF;
  IF OLD.used_at IS NULL AND NEW.used_at IS NOT NULL AND
     (to_jsonb(OLD) - 'used_at' - 'updated_at') =
       (to_jsonb(NEW) - 'used_at' - 'updated_at') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'commercial manifests are immutable';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: admin_roots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_roots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


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
-- Name: recording_studio_billing_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    root_recording_id uuid NOT NULL
);


--
-- Name: recording_studio_billing_billing_admins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_billing_admins (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    root_recording_id uuid NOT NULL
);


--
-- Name: recording_studio_billing_billing_options; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_billing_options (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    recurrence character varying DEFAULT 'one_time'::character varying NOT NULL,
    "interval" character varying,
    interval_count integer,
    quantity_mode character varying DEFAULT 'fixed'::character varying NOT NULL,
    minimum_quantity integer,
    maximum_quantity integer,
    default_quantity integer DEFAULT 1 NOT NULL,
    pricing_model character varying DEFAULT 'flat'::character varying NOT NULL,
    collection_method character varying DEFAULT 'automatic'::character varying NOT NULL,
    payment_terms_days integer DEFAULT 0 NOT NULL,
    trial_days integer DEFAULT 0 NOT NULL,
    proration_policy character varying DEFAULT 'none'::character varying NOT NULL,
    lifecycle_policy character varying DEFAULT 'immediate'::character varying NOT NULL,
    checkout_policy character varying DEFAULT 'allowed'::character varying NOT NULL,
    tax_policy character varying DEFAULT 'exclusive'::character varying NOT NULL,
    feature_values jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT recording_studio_billing_billing_options_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT rs_billing_options_checkout_policy CHECK (((checkout_policy)::text = ANY ((ARRAY['allowed'::character varying, 'required'::character varying, 'disabled'::character varying])::text[]))),
    CONSTRAINT rs_billing_options_collection_method CHECK (((collection_method)::text = ANY ((ARRAY['automatic'::character varying, 'invoice'::character varying])::text[]))),
    CONSTRAINT rs_billing_options_default_maximum CHECK (((maximum_quantity IS NULL) OR (default_quantity <= maximum_quantity))),
    CONSTRAINT rs_billing_options_default_minimum CHECK (((minimum_quantity IS NULL) OR (default_quantity >= minimum_quantity))),
    CONSTRAINT rs_billing_options_default_quantity CHECK ((default_quantity > 0)),
    CONSTRAINT rs_billing_options_interval CHECK (((("interval")::text = ANY ((ARRAY['day'::character varying, 'week'::character varying, 'month'::character varying, 'year'::character varying])::text[])) OR ("interval" IS NULL))),
    CONSTRAINT rs_billing_options_interval_count CHECK (((interval_count > 0) OR (interval_count IS NULL))),
    CONSTRAINT rs_billing_options_lifecycle_policy CHECK (((lifecycle_policy)::text = ANY ((ARRAY['immediate'::character varying, 'scheduled'::character varying])::text[]))),
    CONSTRAINT rs_billing_options_maximum_quantity CHECK (((maximum_quantity > 0) OR (maximum_quantity IS NULL))),
    CONSTRAINT rs_billing_options_minimum_quantity CHECK (((minimum_quantity >= 0) OR (minimum_quantity IS NULL))),
    CONSTRAINT rs_billing_options_payment_terms_days CHECK ((payment_terms_days >= 0)),
    CONSTRAINT rs_billing_options_pricing_model CHECK (((pricing_model)::text = ANY ((ARRAY['flat'::character varying, 'per_unit'::character varying, 'package'::character varying])::text[]))),
    CONSTRAINT rs_billing_options_proration_policy CHECK (((proration_policy)::text = ANY ((ARRAY['none'::character varying, 'prorate'::character varying])::text[]))),
    CONSTRAINT rs_billing_options_quantity_bounds CHECK (((minimum_quantity IS NULL) OR (maximum_quantity IS NULL) OR (minimum_quantity <= maximum_quantity))),
    CONSTRAINT rs_billing_options_quantity_mode CHECK (((quantity_mode)::text = ANY ((ARRAY['fixed'::character varying, 'adjustable'::character varying])::text[]))),
    CONSTRAINT rs_billing_options_recurrence CHECK (((recurrence)::text = ANY ((ARRAY['one_time'::character varying, 'recurring'::character varying])::text[]))),
    CONSTRAINT rs_billing_options_tax_policy CHECK (((tax_policy)::text = ANY ((ARRAY['exclusive'::character varying, 'inclusive'::character varying, 'automatic'::character varying])::text[]))),
    CONSTRAINT rs_billing_options_trial_days CHECK ((trial_days >= 0))
);


--
-- Name: recording_studio_billing_commercial_manifests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_commercial_manifests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    schema_version character varying NOT NULL,
    resolver_version character varying NOT NULL,
    manifest_digest character varying NOT NULL,
    canonical_data jsonb NOT NULL,
    recording_snapshots jsonb DEFAULT '[]'::jsonb NOT NULL,
    snapshot_references jsonb DEFAULT '{}'::jsonb NOT NULL,
    used_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: recording_studio_billing_commercial_publication_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_commercial_publication_candidates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    candidate_digest character varying NOT NULL,
    effective_at timestamp(6) without time zone NOT NULL,
    activated_at timestamp(6) without time zone,
    manifest_digests jsonb DEFAULT '[]'::jsonb NOT NULL,
    recording_snapshots jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    snapshot_envelope jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: recording_studio_billing_cost_cards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_cost_cards (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_studio_billing_cost_cards_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[])))
);


--
-- Name: recording_studio_billing_cost_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_cost_rates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    cost_card_recording_id uuid NOT NULL,
    usage_unit_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    amount_minor bigint NOT NULL,
    currency_code character varying NOT NULL,
    currency_exponent integer NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_studio_billing_cost_rates_amount_minor CHECK ((amount_minor >= 0)),
    CONSTRAINT recording_studio_billing_cost_rates_currency_code CHECK (((currency_code)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT recording_studio_billing_cost_rates_currency_exponent CHECK (((currency_exponent >= 0) AND (currency_exponent <= 3))),
    CONSTRAINT recording_studio_billing_cost_rates_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[])))
);


--
-- Name: recording_studio_billing_feature_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_feature_overrides (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_recording_id uuid NOT NULL,
    feature_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    value jsonb DEFAULT '{}'::jsonb NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_studio_billing_feature_overrides_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[])))
);


--
-- Name: recording_studio_billing_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_features (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    kind character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    definition jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT recording_studio_billing_features_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT rs_billing_features_kind CHECK (((kind)::text = ANY ((ARRAY['boolean'::character varying, 'limit'::character varying, 'allowance'::character varying, 'variant'::character varying])::text[])))
);


--
-- Name: recording_studio_billing_markets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_markets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    country_codes jsonb DEFAULT '[]'::jsonb NOT NULL,
    allowed_currency_codes jsonb DEFAULT '[]'::jsonb NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    specificity integer DEFAULT 0 NOT NULL,
    fallback boolean DEFAULT false NOT NULL,
    ppa_policy character varying DEFAULT 'standard'::character varying NOT NULL,
    rounding_policy character varying DEFAULT 'standard'::character varying NOT NULL,
    tax_presentation_policy character varying DEFAULT 'exclusive'::character varying NOT NULL,
    verification_policy character varying DEFAULT 'none'::character varying NOT NULL,
    country_groups jsonb DEFAULT '{}'::jsonb NOT NULL,
    default_currency_code character varying,
    CONSTRAINT recording_studio_billing_markets_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT rs_billing_markets_priority CHECK ((priority >= 0)),
    CONSTRAINT rs_billing_markets_specificity CHECK ((specificity >= 0))
);


--
-- Name: recording_studio_billing_meters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_meters (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    usage_unit_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    aggregation character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_studio_billing_meters_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT rs_billing_meters_aggregation CHECK (((aggregation)::text = ANY ((ARRAY['sum'::character varying, 'count'::character varying, 'maximum'::character varying, 'latest'::character varying])::text[])))
);


--
-- Name: recording_studio_billing_overage_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_overage_prices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    billing_option_recording_id uuid NOT NULL,
    market_recording_id uuid NOT NULL,
    usage_unit_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    currency_code character varying NOT NULL,
    currency_exponent integer NOT NULL,
    amount_minor bigint NOT NULL,
    pricing_model character varying NOT NULL,
    package_size integer,
    version integer NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    scope character varying DEFAULT 'default'::character varying NOT NULL,
    CONSTRAINT recording_studio_billing_overage_prices_amount_minor CHECK ((amount_minor >= 0)),
    CONSTRAINT recording_studio_billing_overage_prices_currency_code CHECK (((currency_code)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT recording_studio_billing_overage_prices_currency_exponent CHECK (((currency_exponent >= 0) AND (currency_exponent <= 3))),
    CONSTRAINT recording_studio_billing_overage_prices_package_size CHECK (((((pricing_model)::text = 'package'::text) AND (package_size IS NOT NULL) AND (package_size > 0)) OR (((pricing_model)::text = ANY ((ARRAY['flat'::character varying, 'per_unit'::character varying])::text[])) AND (package_size IS NULL)))),
    CONSTRAINT recording_studio_billing_overage_prices_pricing_model CHECK (((pricing_model)::text = ANY ((ARRAY['flat'::character varying, 'per_unit'::character varying, 'package'::character varying])::text[]))),
    CONSTRAINT recording_studio_billing_overage_prices_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT recording_studio_billing_overage_prices_version CHECK ((version >= 1))
);


--
-- Name: recording_studio_billing_plan_updates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_plan_updates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    billing_option_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_studio_billing_plan_updates_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[])))
);


--
-- Name: recording_studio_billing_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_prices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    billing_option_recording_id uuid NOT NULL,
    market_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    currency_code character varying NOT NULL,
    currency_exponent integer NOT NULL,
    amount_minor bigint NOT NULL,
    pricing_model character varying NOT NULL,
    package_size integer,
    version integer NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    scope character varying DEFAULT 'default'::character varying NOT NULL,
    feature_values jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT recording_studio_billing_prices_amount_minor CHECK ((amount_minor >= 0)),
    CONSTRAINT recording_studio_billing_prices_currency_code CHECK (((currency_code)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT recording_studio_billing_prices_currency_exponent CHECK (((currency_exponent >= 0) AND (currency_exponent <= 3))),
    CONSTRAINT recording_studio_billing_prices_package_size CHECK (((((pricing_model)::text = 'package'::text) AND (package_size IS NOT NULL) AND (package_size > 0)) OR (((pricing_model)::text = ANY ((ARRAY['flat'::character varying, 'per_unit'::character varying])::text[])) AND (package_size IS NULL)))),
    CONSTRAINT recording_studio_billing_prices_pricing_model CHECK (((pricing_model)::text = ANY ((ARRAY['flat'::character varying, 'per_unit'::character varying, 'package'::character varying])::text[]))),
    CONSTRAINT recording_studio_billing_prices_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT recording_studio_billing_prices_version CHECK ((version >= 1))
);


--
-- Name: recording_studio_billing_product_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_product_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    rule_type character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    target_product_recording_id uuid,
    conditions jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT recording_studio_billing_product_rules_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[])))
);


--
-- Name: recording_studio_billing_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    kind character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    feature_values jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT recording_studio_billing_products_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT rs_billing_products_kind CHECK (((kind)::text = ANY ((ARRAY['plan'::character varying, 'addon'::character varying, 'credit_pack'::character varying, 'service'::character varying])::text[])))
);


--
-- Name: recording_studio_billing_provider_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_provider_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    billing_admin_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    adapter_key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    name character varying NOT NULL,
    environment character varying DEFAULT 'production'::character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    configuration jsonb DEFAULT '{}'::jsonb NOT NULL,
    capabilities jsonb DEFAULT '[]'::jsonb NOT NULL,
    supported_markets jsonb DEFAULT '[]'::jsonb NOT NULL,
    supported_currencies jsonb DEFAULT '[]'::jsonb NOT NULL,
    checkout_default boolean DEFAULT false NOT NULL,
    CONSTRAINT recording_studio_billing_provider_accounts_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT rs_billing_provider_accounts_provider_format CHECK (((adapter_key)::text ~ '^[a-z][a-z0-9_]*$'::text))
);


--
-- Name: recording_studio_billing_rate_cards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_rate_cards (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_studio_billing_rate_cards_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[])))
);


--
-- Name: recording_studio_billing_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_rates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    rate_card_recording_id uuid NOT NULL,
    usage_unit_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    legacy_monetary_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    conversion_numerator bigint,
    conversion_denominator bigint,
    conversion_decimal numeric(30,12),
    CONSTRAINT recording_studio_billing_rates_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT rs_billing_rates_conversion CHECK ((((conversion_numerator IS NOT NULL) AND (conversion_numerator > 0) AND (conversion_denominator IS NOT NULL) AND (conversion_denominator > 0) AND (conversion_decimal IS NULL)) OR ((conversion_numerator IS NULL) AND (conversion_denominator IS NULL) AND (conversion_decimal IS NOT NULL) AND (conversion_decimal > (0)::numeric)))),
    CONSTRAINT rs_billing_rates_conversion_present CHECK ((NOT ((conversion_numerator IS NULL) AND (conversion_denominator IS NULL) AND (conversion_decimal IS NULL))))
);


--
-- Name: recording_studio_billing_usage_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_usage_units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_studio_billing_usage_units_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[])))
);


--
-- Name: recording_studio_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    recording_id uuid NOT NULL,
    action character varying NOT NULL,
    recordable_type character varying NOT NULL,
    recordable_id uuid NOT NULL,
    previous_recordable_type character varying,
    previous_recordable_id uuid,
    actor_type character varying,
    actor_id uuid,
    impersonator_type character varying,
    impersonator_id uuid,
    occurred_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    idempotency_key character varying,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: recording_studio_recordings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_recordings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    recordable_type character varying NOT NULL,
    recordable_id uuid NOT NULL,
    trashed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    parent_recording_id uuid,
    root_recording_id uuid
);


--
-- Name: recording_studio_root_switchable_selections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_root_switchable_selections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_id character varying,
    actor_type character varying,
    created_at timestamp(6) without time zone NOT NULL,
    device_browser character varying,
    device_key character varying NOT NULL,
    device_label character varying,
    device_platform character varying,
    device_type character varying,
    last_used_at timestamp(6) without time zone NOT NULL,
    root_recording_id uuid NOT NULL,
    scope_key character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_agent text
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying DEFAULT ''::character varying NOT NULL,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL,
    reset_password_token character varying,
    reset_password_sent_at timestamp(6) without time zone,
    remember_created_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspaces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: admin_roots admin_roots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_roots
    ADD CONSTRAINT admin_roots_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: recording_studio_billing_accounts recording_studio_billing_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_accounts
    ADD CONSTRAINT recording_studio_billing_accounts_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_billing_admins recording_studio_billing_billing_admins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_billing_admins
    ADD CONSTRAINT recording_studio_billing_billing_admins_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_billing_options recording_studio_billing_billing_options_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_billing_options
    ADD CONSTRAINT recording_studio_billing_billing_options_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_commercial_manifests recording_studio_billing_commercial_manifests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_commercial_manifests
    ADD CONSTRAINT recording_studio_billing_commercial_manifests_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_commercial_publication_candidates recording_studio_billing_commercial_publication_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_commercial_publication_candidates
    ADD CONSTRAINT recording_studio_billing_commercial_publication_candidates_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_cost_cards recording_studio_billing_cost_cards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_cards
    ADD CONSTRAINT recording_studio_billing_cost_cards_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_cost_rates recording_studio_billing_cost_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_rates
    ADD CONSTRAINT recording_studio_billing_cost_rates_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_feature_overrides recording_studio_billing_feature_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_feature_overrides
    ADD CONSTRAINT recording_studio_billing_feature_overrides_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_features recording_studio_billing_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_features
    ADD CONSTRAINT recording_studio_billing_features_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_markets recording_studio_billing_markets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_markets
    ADD CONSTRAINT recording_studio_billing_markets_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_meters recording_studio_billing_meters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_meters
    ADD CONSTRAINT recording_studio_billing_meters_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_overage_prices recording_studio_billing_overage_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_prices
    ADD CONSTRAINT recording_studio_billing_overage_prices_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_plan_updates recording_studio_billing_plan_updates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_updates
    ADD CONSTRAINT recording_studio_billing_plan_updates_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_prices recording_studio_billing_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_prices
    ADD CONSTRAINT recording_studio_billing_prices_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_product_rules recording_studio_billing_product_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_product_rules
    ADD CONSTRAINT recording_studio_billing_product_rules_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_products recording_studio_billing_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_products
    ADD CONSTRAINT recording_studio_billing_products_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_provider_accounts recording_studio_billing_provider_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_provider_accounts
    ADD CONSTRAINT recording_studio_billing_provider_accounts_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_rate_cards recording_studio_billing_rate_cards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rate_cards
    ADD CONSTRAINT recording_studio_billing_rate_cards_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_rates recording_studio_billing_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rates
    ADD CONSTRAINT recording_studio_billing_rates_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_usage_units recording_studio_billing_usage_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_units
    ADD CONSTRAINT recording_studio_billing_usage_units_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_events recording_studio_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_events
    ADD CONSTRAINT recording_studio_events_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_recordings recording_studio_recordings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_recordings
    ADD CONSTRAINT recording_studio_recordings_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_root_switchable_selections recording_studio_root_switchable_selections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_root_switchable_selections
    ADD CONSTRAINT recording_studio_root_switchable_selections_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: workspaces workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_pkey PRIMARY KEY (id);


--
-- Name: idx_on_account_recording_id_bf46d23ae6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_bf46d23ae6 ON public.recording_studio_billing_feature_overrides USING btree (account_recording_id);


--
-- Name: idx_on_billing_admin_recording_id_e9c004ac4f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_billing_admin_recording_id_e9c004ac4f ON public.recording_studio_billing_provider_accounts USING btree (billing_admin_recording_id);


--
-- Name: idx_on_billing_option_recording_id_4b4b3a8dfa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_billing_option_recording_id_4b4b3a8dfa ON public.recording_studio_billing_overage_prices USING btree (billing_option_recording_id);


--
-- Name: idx_on_billing_option_recording_id_df8562f2e7; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_billing_option_recording_id_df8562f2e7 ON public.recording_studio_billing_plan_updates USING btree (billing_option_recording_id);


--
-- Name: idx_on_billing_option_recording_id_f4dd8ca6e3; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_billing_option_recording_id_f4dd8ca6e3 ON public.recording_studio_billing_prices USING btree (billing_option_recording_id);


--
-- Name: idx_on_cost_card_recording_id_f59059cf73; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_cost_card_recording_id_f59059cf73 ON public.recording_studio_billing_cost_rates USING btree (cost_card_recording_id);


--
-- Name: idx_on_effective_at_7e599d09df; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_effective_at_7e599d09df ON public.recording_studio_billing_commercial_publication_candidates USING btree (effective_at);


--
-- Name: idx_on_feature_recording_id_6dcf40615b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_feature_recording_id_6dcf40615b ON public.recording_studio_billing_feature_overrides USING btree (feature_recording_id);


--
-- Name: idx_on_manifest_digest_b5d415588d; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_manifest_digest_b5d415588d ON public.recording_studio_billing_commercial_manifests USING btree (manifest_digest);


--
-- Name: idx_on_market_recording_id_2ba99ee38f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_market_recording_id_2ba99ee38f ON public.recording_studio_billing_overage_prices USING btree (market_recording_id);


--
-- Name: idx_on_product_recording_id_387e136700; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_product_recording_id_387e136700 ON public.recording_studio_billing_billing_options USING btree (product_recording_id);


--
-- Name: idx_on_product_recording_id_b3abe2c34c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_product_recording_id_b3abe2c34c ON public.recording_studio_billing_features USING btree (product_recording_id);


--
-- Name: idx_on_product_recording_id_cca2c7df22; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_product_recording_id_cca2c7df22 ON public.recording_studio_billing_product_rules USING btree (product_recording_id);


--
-- Name: idx_on_provider_account_recording_id_75eb593078; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_75eb593078 ON public.recording_studio_billing_products USING btree (provider_account_recording_id);


--
-- Name: idx_on_provider_account_recording_id_829622d336; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_829622d336 ON public.recording_studio_billing_rate_cards USING btree (provider_account_recording_id);


--
-- Name: idx_on_provider_account_recording_id_917bf5f52e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_917bf5f52e ON public.recording_studio_billing_markets USING btree (provider_account_recording_id);


--
-- Name: idx_on_provider_account_recording_id_d0aeb02284; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_d0aeb02284 ON public.recording_studio_billing_usage_units USING btree (provider_account_recording_id);


--
-- Name: idx_on_provider_account_recording_id_de683655d9; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_de683655d9 ON public.recording_studio_billing_cost_cards USING btree (provider_account_recording_id);


--
-- Name: idx_on_root_recording_id_d63849b28a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_d63849b28a ON public.recording_studio_billing_commercial_manifests USING btree (root_recording_id);


--
-- Name: idx_on_target_product_recording_id_2d78d41b32; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_target_product_recording_id_2d78d41b32 ON public.recording_studio_billing_product_rules USING btree (target_product_recording_id);


--
-- Name: idx_on_usage_unit_recording_id_20bbb0eead; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_unit_recording_id_20bbb0eead ON public.recording_studio_billing_meters USING btree (usage_unit_recording_id);


--
-- Name: idx_on_usage_unit_recording_id_676a199a57; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_unit_recording_id_676a199a57 ON public.recording_studio_billing_cost_rates USING btree (usage_unit_recording_id);


--
-- Name: idx_on_usage_unit_recording_id_737a9cb844; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_unit_recording_id_737a9cb844 ON public.recording_studio_billing_rates USING btree (usage_unit_recording_id);


--
-- Name: idx_on_usage_unit_recording_id_9e76a066d4; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_unit_recording_id_9e76a066d4 ON public.recording_studio_billing_overage_prices USING btree (usage_unit_recording_id);


--
-- Name: idx_rs_billing_account_root_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_account_root_history ON public.recording_studio_billing_accounts USING btree (root_recording_id);


--
-- Name: idx_rs_billing_admin_root_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_admin_root_history ON public.recording_studio_billing_billing_admins USING btree (root_recording_id);


--
-- Name: idx_rs_billing_one_account_per_root; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_one_account_per_root ON public.recording_studio_recordings USING btree (root_recording_id) WHERE ((recordable_type)::text = 'RecordingStudioBilling::Account'::text);


--
-- Name: idx_rs_billing_one_admin_per_root; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_one_admin_per_root ON public.recording_studio_recordings USING btree (root_recording_id) WHERE ((recordable_type)::text = 'RecordingStudioBilling::BillingAdmin'::text);


--
-- Name: idx_rs_root_switchable_actor_device_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_root_switchable_actor_device_scope ON public.recording_studio_root_switchable_selections USING btree (actor_type, actor_id, device_key, scope_key) WHERE (actor_id IS NOT NULL);


--
-- Name: idx_rs_root_switchable_anonymous_device_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_root_switchable_anonymous_device_scope ON public.recording_studio_root_switchable_selections USING btree (device_key, scope_key) WHERE (actor_id IS NULL);


--
-- Name: idx_rs_root_switchable_root_recording; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_root_switchable_root_recording ON public.recording_studio_root_switchable_selections USING btree (root_recording_id);


--
-- Name: index_admin_roots_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_admin_roots_on_name ON public.admin_roots USING btree (name);


--
-- Name: index_recording_studio_billing_prices_on_market_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_prices_on_market_recording_id ON public.recording_studio_billing_prices USING btree (market_recording_id);


--
-- Name: index_recording_studio_billing_rates_on_rate_card_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_rates_on_rate_card_recording_id ON public.recording_studio_billing_rates USING btree (rate_card_recording_id);


--
-- Name: index_recording_studio_events_on_recording_and_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_recording_studio_events_on_recording_and_idempotency_key ON public.recording_studio_events USING btree (recording_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: index_recording_studio_events_on_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_events_on_recording_id ON public.recording_studio_events USING btree (recording_id);


--
-- Name: index_recording_studio_recordings_on_parent_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_recordings_on_parent_recording_id ON public.recording_studio_recordings USING btree (parent_recording_id);


--
-- Name: index_recording_studio_recordings_on_recordable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_recordings_on_recordable ON public.recording_studio_recordings USING btree (recordable_type, recordable_id);


--
-- Name: index_recording_studio_recordings_on_recordable_parent_trashed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_recordings_on_recordable_parent_trashed ON public.recording_studio_recordings USING btree (recordable_type, recordable_id, parent_recording_id, trashed_at);


--
-- Name: index_rs_recordings_on_root_recording; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rs_recordings_on_root_recording ON public.recording_studio_recordings USING btree (root_recording_id);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: index_users_on_reset_password_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_reset_password_token ON public.users USING btree (reset_password_token);


--
-- Name: rs_billing_publication_candidate_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX rs_billing_publication_candidate_identity ON public.recording_studio_billing_commercial_publication_candidates USING btree (root_recording_id, effective_at);


--
-- Name: rs_billing_publication_candidates_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX rs_billing_publication_candidates_digest ON public.recording_studio_billing_commercial_publication_candidates USING btree (candidate_digest);


--
-- Name: recording_studio_billing_billing_options recording_studio_billing_billing_options_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_billing_options_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_billing_options FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::BillingOption');


--
-- Name: recording_studio_billing_cost_cards recording_studio_billing_cost_cards_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_cost_cards_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_cost_cards FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::CostCard');


--
-- Name: recording_studio_billing_cost_rates recording_studio_billing_cost_rates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_cost_rates_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_cost_rates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::CostRate');


--
-- Name: recording_studio_billing_feature_overrides recording_studio_billing_feature_overrides_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_feature_overrides_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_feature_overrides FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::FeatureOverride');


--
-- Name: recording_studio_billing_features recording_studio_billing_features_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_features_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_features FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Feature');


--
-- Name: recording_studio_billing_markets recording_studio_billing_markets_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_markets_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_markets FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Market');


--
-- Name: recording_studio_billing_meters recording_studio_billing_meters_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_meters_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_meters FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Meter');


--
-- Name: recording_studio_billing_overage_prices recording_studio_billing_overage_prices_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_overage_prices_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_overage_prices FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::OveragePrice');


--
-- Name: recording_studio_billing_plan_updates recording_studio_billing_plan_updates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_plan_updates_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_plan_updates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::PlanUpdate');


--
-- Name: recording_studio_billing_prices recording_studio_billing_prices_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_prices_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_prices FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Price');


--
-- Name: recording_studio_billing_product_rules recording_studio_billing_product_rules_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_product_rules_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_product_rules FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::ProductRule');


--
-- Name: recording_studio_billing_products recording_studio_billing_products_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_products_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_products FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Product');


--
-- Name: recording_studio_billing_provider_accounts recording_studio_billing_provider_accounts_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_provider_accounts_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_provider_accounts FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::ProviderAccount');


--
-- Name: recording_studio_billing_rate_cards recording_studio_billing_rate_cards_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_rate_cards_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_rate_cards FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::RateCard');


--
-- Name: recording_studio_billing_rates recording_studio_billing_rates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_rates_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_rates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Rate');


--
-- Name: recording_studio_billing_usage_units recording_studio_billing_usage_units_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_usage_units_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_usage_units FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::UsageUnit');


--
-- Name: recording_studio_billing_commercial_publication_candidates rs_billing_candidates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_candidates_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_commercial_publication_candidates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_candidate_history();


--
-- Name: recording_studio_billing_commercial_manifests rs_billing_manifests_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_manifests_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_commercial_manifests FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_manifest_history();


--
-- Name: recording_studio_billing_provider_accounts fk_rails_1247aa36a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_provider_accounts
    ADD CONSTRAINT fk_rails_1247aa36a0 FOREIGN KEY (billing_admin_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_feature_overrides fk_rails_17bde42a64; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_feature_overrides
    ADD CONSTRAINT fk_rails_17bde42a64 FOREIGN KEY (feature_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_rates fk_rails_22d4fb3576; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rates
    ADD CONSTRAINT fk_rails_22d4fb3576 FOREIGN KEY (rate_card_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_recordings fk_rails_26012d5ca3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_recordings
    ADD CONSTRAINT fk_rails_26012d5ca3 FOREIGN KEY (parent_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_billing_options fk_rails_33726a97d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_billing_options
    ADD CONSTRAINT fk_rails_33726a97d6 FOREIGN KEY (product_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_plan_updates fk_rails_511ec0e839; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_updates
    ADD CONSTRAINT fk_rails_511ec0e839 FOREIGN KEY (billing_option_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_rates fk_rails_5c82417e3e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rates
    ADD CONSTRAINT fk_rails_5c82417e3e FOREIGN KEY (usage_unit_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_cost_rates fk_rails_6180561f6f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_rates
    ADD CONSTRAINT fk_rails_6180561f6f FOREIGN KEY (cost_card_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_accounts fk_rails_618f9da784; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_accounts
    ADD CONSTRAINT fk_rails_618f9da784 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_billing_admins fk_rails_61d701f772; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_billing_admins
    ADD CONSTRAINT fk_rails_61d701f772 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_prices fk_rails_62af4fe846; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_prices
    ADD CONSTRAINT fk_rails_62af4fe846 FOREIGN KEY (billing_option_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_overage_prices fk_rails_71961e29ca; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_prices
    ADD CONSTRAINT fk_rails_71961e29ca FOREIGN KEY (usage_unit_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_prices fk_rails_71e092b121; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_prices
    ADD CONSTRAINT fk_rails_71e092b121 FOREIGN KEY (market_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_meters fk_rails_754812330d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_meters
    ADD CONSTRAINT fk_rails_754812330d FOREIGN KEY (usage_unit_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_cost_cards fk_rails_7fe81ededc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_cards
    ADD CONSTRAINT fk_rails_7fe81ededc FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_overage_prices fk_rails_9546dcb8cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_prices
    ADD CONSTRAINT fk_rails_9546dcb8cf FOREIGN KEY (billing_option_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_features fk_rails_9eae67f745; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_features
    ADD CONSTRAINT fk_rails_9eae67f745 FOREIGN KEY (product_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_product_rules fk_rails_9eb3a96d12; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_product_rules
    ADD CONSTRAINT fk_rails_9eb3a96d12 FOREIGN KEY (product_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_overage_prices fk_rails_bd104db33e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_prices
    ADD CONSTRAINT fk_rails_bd104db33e FOREIGN KEY (market_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_feature_overrides fk_rails_c386383455; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_feature_overrides
    ADD CONSTRAINT fk_rails_c386383455 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_rate_cards fk_rails_ca9368a435; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rate_cards
    ADD CONSTRAINT fk_rails_ca9368a435 FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_product_rules fk_rails_d8f5b1928a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_product_rules
    ADD CONSTRAINT fk_rails_d8f5b1928a FOREIGN KEY (target_product_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_markets fk_rails_e81c1eaa3f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_markets
    ADD CONSTRAINT fk_rails_e81c1eaa3f FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_cost_rates fk_rails_e9f02ab3e1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_rates
    ADD CONSTRAINT fk_rails_e9f02ab3e1 FOREIGN KEY (usage_unit_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_products fk_rails_f2d073142d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_products
    ADD CONSTRAINT fk_rails_f2d073142d FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_events fk_rails_ff21937ccd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_events
    ADD CONSTRAINT fk_rails_ff21937ccd FOREIGN KEY (recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_usage_units fk_rails_ff6cd411aa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_units
    ADD CONSTRAINT fk_rails_ff6cd411aa FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_recordings fk_rails_ffcd14a670; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_recordings
    ADD CONSTRAINT fk_rails_ffcd14a670 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_commercial_publication_candidates fk_rs_billing_candidates_root; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_commercial_publication_candidates
    ADD CONSTRAINT fk_rs_billing_candidates_root FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_commercial_manifests fk_rs_billing_manifests_root; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_commercial_manifests
    ADD CONSTRAINT fk_rs_billing_manifests_root FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260810000010'),
('20260810000009'),
('20260810000008'),
('20260810000007'),
('20260810000006'),
('20260810000005'),
('20260810000004'),
('20260810000003'),
('20260810000002'),
('20260810000001'),
('20260612000000'),
('20260421000000'),
('20260217233016'),
('20260217072940'),
('20260217072923'),
('20260217072826'),
('20260217072825'),
('20260217072824'),
('20260217072823'),
('20260217072822'),
('20260217072821'),
('20260217072820'),
('20260217072819'),
('20260217072818'),
('20260217072817'),
('20260217072816'),
('20260217072815'),
('20250101000000');
