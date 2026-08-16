-- Clean-install Recording Studio Billing schema.
-- This file is the canonical PostgreSQL install for a new host. It is not an
-- upgrade path from earlier development snapshots.
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

-- Name: rs_billing_country_code_array_valid(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_country_code_array_valid(value jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $_$
  SELECT jsonb_typeof(value) = 'array'
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(value) AS code
      WHERE code !~ '^[A-Z]{2}$'
    );
$_$;

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

-- Name: rs_billing_protect_checkout_attempt(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_checkout_attempt() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE expected_attempt_number integer;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'checkout attempts are append-only'; END IF;
  IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_checkout_intents intent WHERE intent.id = NEW.checkout_intent_id AND intent.financial_command_id = NEW.financial_command_id) THEN
    RAISE EXCEPTION 'checkout attempt command must belong to its intent';
  END IF;
  IF TG_OP = 'INSERT' THEN
    SELECT COALESCE(MAX(attempt_number), 0) + 1 INTO expected_attempt_number FROM recording_studio_billing_checkout_attempts WHERE checkout_intent_id = NEW.checkout_intent_id;
    IF NEW.attempt_number IS DISTINCT FROM expected_attempt_number OR NEW.state <> 'pending' OR NEW.completed_at IS NOT NULL THEN RAISE EXCEPTION 'checkout attempts must begin sequentially and pending'; END IF;
    RETURN NEW;
  END IF;
  IF OLD.id IS DISTINCT FROM NEW.id OR OLD.checkout_intent_id IS DISTINCT FROM NEW.checkout_intent_id OR OLD.financial_command_id IS DISTINCT FROM NEW.financial_command_id OR OLD.attempt_number IS DISTINCT FROM NEW.attempt_number OR OLD.created_at IS DISTINCT FROM NEW.created_at OR OLD.completed_at IS NOT NULL THEN RAISE EXCEPTION 'checkout attempt history is immutable'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_checkout_item(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_checkout_item() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION 'checkout intent items are immutable'; END;
$$;

-- Name: rs_billing_protect_command_attempt(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_command_attempt() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE command_idempotency_key text;
DECLARE expected_attempt_number integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'financial command attempts are append-only';
  END IF;
  SELECT provider_idempotency_key INTO command_idempotency_key
  FROM recording_studio_billing_financial_commands
  WHERE id = NEW.financial_command_id;
  IF NEW.provider_idempotency_key IS DISTINCT FROM command_idempotency_key THEN
    RAISE EXCEPTION 'attempt idempotency key must match its financial command';
  END IF;
  IF NOT rs_billing_safe_financial_json(NEW.normalized_result)
     OR NOT rs_billing_safe_financial_json(NEW.safe_error_details)
     OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN
    RAISE EXCEPTION 'financial command attempt contains unsafe persisted data';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.state <> 'processing' OR NEW.completed_at IS NOT NULL THEN
      RAISE EXCEPTION 'financial command attempts must begin processing and incomplete';
    END IF;
    SELECT COALESCE(MAX(attempt_number), 0) + 1 INTO expected_attempt_number
    FROM recording_studio_billing_financial_command_attempts
    WHERE financial_command_id = NEW.financial_command_id;
    IF NEW.attempt_number IS DISTINCT FROM expected_attempt_number THEN
      RAISE EXCEPTION 'financial command attempts must be sequential';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.id IS DISTINCT FROM NEW.id
     OR OLD.created_at IS DISTINCT FROM NEW.created_at
     OR OLD.financial_command_id IS DISTINCT FROM NEW.financial_command_id
     OR OLD.attempt_number IS DISTINCT FROM NEW.attempt_number
     OR OLD.provider_idempotency_key IS DISTINCT FROM NEW.provider_idempotency_key
     OR OLD.started_at IS DISTINCT FROM NEW.started_at
     OR OLD.completed_at IS NOT NULL
     OR NEW.completed_at IS NULL
     OR NEW.state NOT IN ('succeeded', 'failed', 'uncertain', 'requires_reconciliation', 'cancelled') THEN
    RAISE EXCEPTION 'financial command attempt history is immutable';
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_commercial_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_commercial_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
  IF TG_ARGV[0] = 'RecordingStudioBilling::FeatureOverride' THEN
    IF NEW.state <> 'draft' AND
       current_setting('recording_studio_billing.authorized_feature_override', true) IS DISTINCT FROM 'on' THEN
      RAISE EXCEPTION 'feature override revision requires an authorized transaction';
    END IF;
  ELSIF NEW.state <> 'draft' AND
        current_setting('recording_studio_billing.authorized_publication', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'commercial publication requires an authorized transaction';
  END IF;
  RETURN NEW;
END IF;

  IF OLD.state IN ('published', 'retired') OR NOT EXISTS (
    SELECT 1
    FROM recording_studio_recordings
    WHERE recordable_type = TG_ARGV[0]
      AND recordable_id = OLD.id
  ) THEN
    RAISE EXCEPTION 'published, retired, and historical commercial records are immutable';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.state = 'draft' AND NEW.state <> 'draft' THEN
    RAISE EXCEPTION 'commercial state changes must create an authorized revision';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_commercial_projection(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_commercial_projection() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'commercial financial projections are immutable';
END;
$$;

-- Name: rs_billing_protect_credit_ledger_entry(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_credit_ledger_entry() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'credit ledger entries are append-only'; END IF;
  IF NEW.direction = 'credit' THEN
    IF NOT EXISTS (
      SELECT 1 FROM recording_studio_billing_purchase_effects effect
      JOIN recording_studio_billing_purchases purchase ON purchase.id = effect.purchase_id
      WHERE effect.id = NEW.purchase_effect_id AND effect.effect_kind = 'credit_pack'
        AND effect.root_recording_id = NEW.root_recording_id AND effect.account_recording_id = NEW.account_recording_id
        AND effect.manifest_digest = NEW.manifest_digest AND purchase.manifest_digest = NEW.manifest_digest
        AND purchase.product_recording_id = NEW.product_recording_id
        AND purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.credit_key, 'definition', 'type'] = '"allowance"'::jsonb
        AND jsonb_typeof(purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.credit_key, 'value']) = 'number'
        AND (purchase.commercial_snapshot #>> ARRAY['canonical_data', 'features', NEW.credit_key, 'value'])::bigint * purchase.quantity = NEW.amount
    ) THEN RAISE EXCEPTION 'credit ledger source authority is invalid'; END IF;
  ELSIF NEW.direction = 'debit' THEN
    IF NOT EXISTS (
      SELECT 1 FROM recording_studio_billing_usage_events event
      WHERE event.id = NEW.usage_event_id AND event.root_recording_id = NEW.root_recording_id
        AND event.account_recording_id = NEW.account_recording_id AND event.usage_key = NEW.credit_key
        AND event.idempotency_key = NEW.idempotency_key
    ) OR NOT EXISTS (
      SELECT 1 FROM recording_studio_billing_credit_ledger_entries credit
      WHERE credit.direction = 'credit' AND credit.root_recording_id = NEW.root_recording_id
        AND credit.account_recording_id = NEW.account_recording_id AND credit.product_recording_id = NEW.product_recording_id
        AND credit.credit_key = NEW.credit_key AND credit.manifest_digest = NEW.manifest_digest
    ) OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN
      RAISE EXCEPTION 'credit debit source authority is invalid';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
  'recording-studio-billing:credits:' || NEW.root_recording_id::text || ':' || NEW.account_recording_id::text || ':' || NEW.product_recording_id::text,
  0
));
IF COALESCE((
  SELECT SUM(amount) FROM recording_studio_billing_credit_ledger_entries
  WHERE root_recording_id = NEW.root_recording_id AND account_recording_id = NEW.account_recording_id
    AND product_recording_id = NEW.product_recording_id
), 0) + NEW.amount < 0 THEN
  RAISE EXCEPTION 'credit debit would make the balance negative';
END IF;

  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_entitlement_projection(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_entitlement_projection() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'entitlement projections are append-only'; END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM recording_studio_recordings root
    JOIN recording_studio_recordings account_recording ON account_recording.id = NEW.account_recording_id
    JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
    WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL
      AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = root.id AND account_recording.parent_recording_id = root.id AND account_recording.trashed_at IS NULL AND account.root_recording_id = root.id
  ) THEN RAISE EXCEPTION 'entitlement root or account authority is invalid'; END IF;
  IF NEW.source_type = 'RecordingStudioBilling::SubscriptionItemVersion' AND NOT EXISTS (
    SELECT 1 FROM recording_studio_billing_subscription_item_versions source
    JOIN recording_studio_billing_subscriptions subscription ON subscription.id = source.subscription_id
    WHERE source.id = NEW.source_id AND source.root_recording_id = NEW.root_recording_id AND source.account_recording_id = NEW.account_recording_id AND source.manifest_digest = NEW.manifest_digest AND subscription.root_recording_id = NEW.root_recording_id AND subscription.account_recording_id = NEW.account_recording_id
  ) THEN RAISE EXCEPTION 'entitlement subscription source authority is invalid'; END IF;
  IF NEW.source_type = 'RecordingStudioBilling::SubscriptionItemVersion' AND NOT EXISTS (
    SELECT 1 FROM recording_studio_billing_subscription_item_versions source
    WHERE source.id = NEW.source_id AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'type'] = to_jsonb(NEW.feature_kind)
      AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'merge_rule'] = to_jsonb(NEW.merge_rule)
      AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'value'] = NEW.value
  ) THEN RAISE EXCEPTION 'entitlement subscription grant does not match frozen source'; END IF;
  IF NEW.source_type = 'RecordingStudioBilling::PurchaseEffect' AND NOT EXISTS (
    SELECT 1 FROM recording_studio_billing_purchase_effects source
    JOIN recording_studio_billing_purchases purchase ON purchase.id = source.purchase_id
    WHERE source.id = NEW.source_id AND source.root_recording_id = NEW.root_recording_id AND source.account_recording_id = NEW.account_recording_id AND source.manifest_digest = NEW.manifest_digest AND purchase.manifest_digest = NEW.manifest_digest
  ) THEN RAISE EXCEPTION 'entitlement purchase effect source authority is invalid'; END IF;
  IF NEW.source_type = 'RecordingStudioBilling::PurchaseEffect' AND NOT EXISTS (
    SELECT 1 FROM recording_studio_billing_purchase_effects source
    JOIN recording_studio_billing_purchases purchase ON purchase.id = source.purchase_id
    WHERE source.id = NEW.source_id AND purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'type'] = to_jsonb(NEW.feature_kind)
      AND purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'merge_rule'] = to_jsonb(NEW.merge_rule)
      AND purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'value'] = NEW.value
  ) THEN RAISE EXCEPTION 'entitlement purchase grant does not match frozen source'; END IF;
  IF NOT rs_billing_safe_financial_json(jsonb_build_object('value', NEW.value)) THEN RAISE EXCEPTION 'entitlement grant contains unsafe data'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_financial_command(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_financial_command() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'financial commands are durable';
  END IF;
  IF OLD.operation_id IS DISTINCT FROM NEW.operation_id
     OR OLD.command_type IS DISTINCT FROM NEW.command_type
     OR OLD.root_recording_id IS DISTINCT FROM NEW.root_recording_id
     OR OLD.account_recording_id IS DISTINCT FROM NEW.account_recording_id
     OR OLD.provider_account_recording_id IS DISTINCT FROM NEW.provider_account_recording_id
     OR OLD.provider_adapter_key IS DISTINCT FROM NEW.provider_adapter_key
     OR OLD.calculator_key IS DISTINCT FROM NEW.calculator_key
     OR OLD.calculator_mode IS DISTINCT FROM NEW.calculator_mode
     OR OLD.canonical_request IS DISTINCT FROM NEW.canonical_request
     OR OLD.request_fingerprint IS DISTINCT FROM NEW.request_fingerprint
     OR OLD.local_idempotency_key IS DISTINCT FROM NEW.local_idempotency_key
     OR OLD.provider_idempotency_key IS DISTINCT FROM NEW.provider_idempotency_key THEN
    RAISE EXCEPTION 'financial command authority is immutable';
  END IF;
  RETURN NEW;
END;
$$;

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

-- Name: rs_billing_protect_meter_aggregation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_meter_aggregation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'meter aggregations are append-only'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM recording_studio_recordings root
    JOIN recording_studio_recordings account_recording ON account_recording.id = NEW.account_recording_id
    JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
    WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL
      AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = root.id AND account_recording.parent_recording_id = root.id AND account_recording.trashed_at IS NULL AND account.root_recording_id = root.id
  ) OR NOT EXISTS (
    SELECT 1 FROM recording_studio_billing_commercial_manifests manifest
    WHERE manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL
      AND manifest.canonical_data #> ARRAY['usage_rating', 'meters', NEW.meter_recording_id::text, 'usage_unit_recording_id'] = to_jsonb(NEW.usage_unit_recording_id::text)
      AND manifest.canonical_data #> ARRAY['usage_rating', 'meters', NEW.meter_recording_id::text, 'aggregation'] = to_jsonb(NEW.aggregation)
      AND NEW.input_snapshot ->> 'meter_recording_id' = NEW.meter_recording_id::text
      AND NEW.input_snapshot ->> 'usage_unit_recording_id' = NEW.usage_unit_recording_id::text
      AND NEW.input_snapshot ->> 'aggregation' = NEW.aggregation
      AND NEW.input_snapshot ->> 'window_starts_at' = to_char(NEW.window_starts_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
      AND NEW.input_snapshot ->> 'window_ends_at' = to_char(NEW.window_ends_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
      AND NEW.usage_event_ids = ARRAY(
        SELECT event.id FROM recording_studio_billing_usage_events event
        WHERE event.root_recording_id = NEW.root_recording_id AND event.account_recording_id = NEW.account_recording_id
          AND event.usage_key = manifest.canonical_data #>> ARRAY['usage_rating', 'meters', NEW.meter_recording_id::text, 'usage_key']
          AND event.occurred_at >= NEW.window_starts_at AND event.occurred_at < NEW.window_ends_at
        ORDER BY event.occurred_at, event.id
      )
      AND NEW.input_snapshot -> 'events' = COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', event.id::text, 'quantity', event.quantity) ORDER BY event.occurred_at, event.id)
        FROM recording_studio_billing_usage_events event WHERE event.id = ANY(NEW.usage_event_ids)
      ), '[]'::jsonb)
      AND NEW.quantity = CASE NEW.aggregation
        WHEN 'sum' THEN (SELECT SUM(event.quantity) FROM recording_studio_billing_usage_events event WHERE event.id = ANY(NEW.usage_event_ids))
        WHEN 'count' THEN cardinality(NEW.usage_event_ids)
        WHEN 'maximum' THEN (SELECT MAX(event.quantity) FROM recording_studio_billing_usage_events event WHERE event.id = ANY(NEW.usage_event_ids))
        WHEN 'latest' THEN (SELECT event.quantity FROM recording_studio_billing_usage_events event WHERE event.id = ANY(NEW.usage_event_ids) ORDER BY event.occurred_at DESC, event.id DESC LIMIT 1)
      END
      AND NEW.input_digest = encode(digest(NEW.input_snapshot::text, 'sha256'), 'hex')
  ) OR NOT rs_billing_safe_financial_json(NEW.input_snapshot) OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN
    RAISE EXCEPTION 'meter aggregation source authority is invalid';
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_overage_calculation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_overage_calculation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'overage calculations are append-only'; END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM recording_studio_billing_usage_allocations allocation
    JOIN recording_studio_billing_rated_usages rated ON rated.id = allocation.rated_usage_id
    JOIN recording_studio_billing_commercial_manifests manifest ON manifest.manifest_digest = rated.manifest_digest
    CROSS JOIN LATERAL jsonb_array_elements(manifest.canonical_data -> 'overage_prices') price
    WHERE allocation.id = NEW.usage_allocation_id AND allocation.excess_quantity > 0
      AND manifest.used_at IS NOT NULL
      AND NEW.excess_quantity = allocation.excess_quantity
      AND NEW.overage_price_recording_id::text = price ->> 'overage_price_recording_id'
      AND NEW.rate_snapshot ->> 'manifest_digest' = rated.manifest_digest
      AND NEW.rate_snapshot ->> 'overage_price_recording_id' = price ->> 'overage_price_recording_id'
      AND NEW.rate_snapshot ->> 'market_recording_id' = manifest.canonical_data #>> '{usage_settlement,market_recording_id}'
      AND price ->> 'market_recording_id' = manifest.canonical_data #>> '{usage_settlement,market_recording_id}'
      AND NEW.rate_snapshot ->> 'usage_unit_recording_id' = rated.rate_snapshot #>> '{meter,usage_unit_recording_id}'
      AND price ->> 'usage_unit_recording_id' = rated.rate_snapshot #>> '{meter,usage_unit_recording_id}'
      AND NEW.currency_code = price ->> 'currency_code'
      AND NEW.currency_exponent = (price ->> 'currency_exponent')::integer
      AND NEW.rate_snapshot ->> 'currency_code' = price ->> 'currency_code'
      AND (NEW.rate_snapshot ->> 'currency_exponent')::integer = (price ->> 'currency_exponent')::integer
      AND NEW.rate_snapshot ->> 'pricing_model' = price ->> 'pricing_model'
      AND COALESCE((NEW.rate_snapshot ->> 'package_size')::integer, 1) = COALESCE((price ->> 'package_size')::integer, 1)
      AND (NEW.rate_snapshot ->> 'amount_minor')::bigint = (price ->> 'amount_minor')::bigint
      AND NEW.rate_snapshot ->> 'scope' = price ->> 'scope'
      AND (NEW.rate_snapshot ->> 'version')::integer = (price ->> 'version')::integer
      AND NEW.amount_minor = CASE price ->> 'pricing_model'
        WHEN 'flat' THEN (price ->> 'amount_minor')::bigint
        WHEN 'per_unit' THEN allocation.excess_quantity * (price ->> 'amount_minor')::bigint
        WHEN 'package' THEN ((allocation.excess_quantity * (price ->> 'amount_minor')::bigint) + COALESCE((price ->> 'package_size')::integer, 1) - 1) / COALESCE((price ->> 'package_size')::integer, 1)
      END
  ) THEN RAISE EXCEPTION 'overage calculation source authority is invalid'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_purchase(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_purchase() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'purchases are immutable'; END IF;
  IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_checkout_intents intent JOIN recording_studio_billing_checkout_intent_items item ON item.id = NEW.checkout_intent_item_id WHERE intent.id = NEW.checkout_intent_id AND intent.root_recording_id = NEW.root_recording_id AND intent.account_recording_id = NEW.account_recording_id AND item.checkout_intent_id = intent.id AND item.manifest_digest = NEW.manifest_digest AND EXISTS (SELECT 1 FROM recording_studio_billing_commercial_manifests manifest WHERE manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL)) THEN RAISE EXCEPTION 'purchase source authority is invalid'; END IF;
  IF NOT rs_billing_safe_financial_json(NEW.commercial_snapshot) THEN RAISE EXCEPTION 'purchase contains unsafe data'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_purchase_effect(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_purchase_effect() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'purchase effects are append-only'; END IF;
  IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_purchases purchase WHERE purchase.id = NEW.purchase_id AND purchase.root_recording_id = NEW.root_recording_id AND purchase.account_recording_id = NEW.account_recording_id AND purchase.manifest_digest = NEW.manifest_digest) OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN RAISE EXCEPTION 'purchase effect authority or payload is invalid'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_rated_usage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_rated_usage() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'rated usages are append-only'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM recording_studio_billing_meter_aggregations aggregation
    JOIN recording_studio_billing_commercial_manifests manifest ON manifest.manifest_digest = NEW.manifest_digest
    WHERE aggregation.id = NEW.meter_aggregation_id AND aggregation.root_recording_id = NEW.root_recording_id
      AND aggregation.account_recording_id = NEW.account_recording_id AND aggregation.manifest_digest = NEW.manifest_digest
      AND aggregation.window_starts_at = NEW.window_starts_at AND aggregation.window_ends_at = NEW.window_ends_at
      AND manifest.used_at IS NOT NULL AND NEW.aggregation_snapshot = aggregation.input_snapshot
      AND NEW.rate_snapshot -> 'rate' = manifest.canonical_data #> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text]
      AND NEW.rate_snapshot -> 'customer_rate' = manifest.canonical_data #> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text]
      AND NEW.quantity = aggregation.quantity * (manifest.canonical_data #>> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text, 'conversion_numerator'])::bigint / (manifest.canonical_data #>> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text, 'conversion_denominator'])::bigint
  ) OR NEW.customer_amount_minor IS NOT NULL OR NEW.customer_currency_code IS NOT NULL OR NEW.customer_currency_exponent IS NOT NULL THEN
    RAISE EXCEPTION 'rated usage source authority is invalid';
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_rated_usage_settlement(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_rated_usage_settlement() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'rated usage settlements are append-only'; END IF;
  IF NEW.usage_period_id IS NULL OR NEW.rated_usage_id IS NOT NULL OR NOT EXISTS (
    SELECT 1 FROM recording_studio_billing_usage_periods period
    JOIN recording_studio_billing_financial_commands command ON command.id = NEW.financial_command_id
    JOIN recording_studio_billing_commercial_manifests manifest ON manifest.manifest_digest = NEW.manifest_digest
    WHERE period.id = NEW.usage_period_id AND period.state = 'closed'
      AND period.root_recording_id = NEW.root_recording_id AND period.account_recording_id = NEW.account_recording_id
      AND command.command_type = 'usage_settlement' AND command.root_recording_id = NEW.root_recording_id
      AND command.account_recording_id = NEW.account_recording_id AND command.provider_account_recording_id = NEW.provider_account_recording_id
      AND command.canonical_request -> 'request' = NEW.canonical_request
      AND command.request_fingerprint = NEW.request_fingerprint
      AND NEW.canonical_request ->> 'usage_period_id' = period.id::text
      AND manifest.used_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'usage period settlement source authority is invalid'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_reconciliation_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_reconciliation_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'reconciliation history is append-only'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_subscription_item_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_subscription_item_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE expected_version integer;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'subscription item versions are append-only'; END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.source_type = 'checkout' AND NOT EXISTS (
      SELECT 1 FROM recording_studio_billing_checkout_intents intent
      JOIN recording_studio_billing_checkout_intent_items item ON item.id = NEW.checkout_intent_item_id
      WHERE intent.id = NEW.checkout_intent_id AND item.checkout_intent_id = intent.id
        AND intent.root_recording_id = NEW.root_recording_id AND intent.account_recording_id = NEW.account_recording_id
        AND item.manifest_digest = NEW.manifest_digest AND item.commercial_manifest = NEW.source_snapshot
        AND item.commercial_manifest = NEW.commercial_snapshot
    ) THEN RAISE EXCEPTION 'checkout source authority is invalid'; END IF;
    IF NEW.source_type = 'subscription_change' AND NOT EXISTS (
      SELECT 1 FROM recording_studio_billing_subscription_change_intents change
      WHERE change.id = NEW.source_id AND change.subscription_id = NEW.subscription_id
        AND change.root_recording_id = NEW.root_recording_id AND change.account_recording_id = NEW.account_recording_id
        AND (change.proposed_manifest_digest = NEW.manifest_digest
          OR (change.change_kind = 'resumption' AND change.current_manifest_digest = NEW.manifest_digest))
        AND change.state = 'applied'
        AND NEW.source_snapshot = CASE
          WHEN change.change_kind = 'resumption' THEN change.frozen_terms -> 'current'
          ELSE change.frozen_terms -> 'proposed'
        END
        AND NEW.commercial_snapshot = NEW.source_snapshot
    ) THEN RAISE EXCEPTION 'subscription change source authority is invalid'; END IF;
    SELECT COALESCE(MAX(version_number), 0) + 1 INTO expected_version
    FROM recording_studio_billing_subscription_item_versions WHERE subscription_item_id = NEW.subscription_item_id;
    IF NEW.version_number IS DISTINCT FROM expected_version THEN RAISE EXCEPTION 'subscription item versions must be sequential'; END IF;
    IF NOT rs_billing_safe_financial_json(NEW.commercial_snapshot) OR NOT rs_billing_safe_financial_json(NEW.source_snapshot) THEN RAISE EXCEPTION 'subscription item version contains unsafe data'; END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(OLD) - 'effective_ends_at' - 'superseded_at' - 'updated_at') IS DISTINCT FROM (to_jsonb(NEW) - 'effective_ends_at' - 'superseded_at' - 'updated_at') OR OLD.effective_ends_at IS NOT NULL OR NEW.effective_ends_at IS NULL THEN RAISE EXCEPTION 'subscription item version history is immutable'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_tax_calculation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_tax_calculation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'tax calculations are immutable and append-only';
END;
$$;

-- Name: rs_billing_protect_usage_correction(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_usage_correction() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'usage corrections are append-only'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_usage_credit_grant(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_usage_credit_grant() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'usage credit grants are append-only'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_usage_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_usage_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'usage events are append-only'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM recording_studio_recordings root
    JOIN recording_studio_recordings account_recording ON account_recording.id = NEW.account_recording_id
    JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
    WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL
      AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = root.id AND account_recording.parent_recording_id = root.id AND account_recording.trashed_at IS NULL AND account.root_recording_id = root.id
  ) THEN RAISE EXCEPTION 'usage event root or account authority is invalid'; END IF;
  IF NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN RAISE EXCEPTION 'usage event contains unsafe metadata'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_protect_usage_ledger_entry(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_usage_ledger_entry() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'usage ledger entries are append-only'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_safe_financial_json(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_safe_financial_json(payload jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
BEGIN
  RETURN NOT EXISTS (
    WITH RECURSIVE nodes(key, value) AS (
      SELECT NULL::text, payload
      UNION ALL
      SELECT child.key, child.value
      FROM nodes
      CROSS JOIN LATERAL (
        SELECT entry.key, entry.value
        FROM jsonb_each(CASE WHEN jsonb_typeof(nodes.value) = 'object' THEN nodes.value ELSE '{}'::jsonb END) entry
        UNION ALL
        SELECT NULL::text, element.value
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(nodes.value) = 'array' THEN nodes.value ELSE '[]'::jsonb END) element
      ) child
    )
    SELECT 1
    FROM nodes
    WHERE key ~* '(authorization|credential|password|secret|token|api[_-]?key|private[_-]?key|signature|card[_-]?(number|cvc|cvv)|payment[_-]?(nonce|credential)|bank[_-]?account|routing[_-]?number|provider[_-]?(url|uri|id|identifier|account[_-]?id|customer[_-]?id|response|payload|body)|raw[_-]?(provider|response|payload|body)|(^|[_-])(tax|vat)[_-]?(id|identifier|number)|(^|[_-])(email|phone|address|postal[_-]?code|ip[_-]?address)|(^|[_-])(url|uri)$)'
       OR (jsonb_typeof(value) = 'string' AND trim(both '"' from value::text) ~* '^[[:space:]]*(https?|ftp)://')
  );
END;
$_$;

-- Name: rs_billing_sorted_manifest_set(jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_sorted_manifest_set(digests jsonb, anchor text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
DECLARE
  digest text;
  previous_digest text;
BEGIN
  IF jsonb_typeof(digests) <> 'array'
     OR jsonb_array_length(digests) = 0
     OR digests ->> 0 <> anchor THEN
    RETURN false;
  END IF;

  FOR digest IN SELECT jsonb_array_elements_text(digests)
  LOOP
    IF digest !~ '^[0-9a-f]{64}$'
       OR (previous_digest IS NOT NULL AND digest <= previous_digest) THEN
      RETURN false;
    END IF;
    previous_digest := digest;
  END LOOP;

  RETURN true;
END;
$_$;

-- Name: rs_billing_subscription_lifecycle(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_subscription_lifecycle() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'subscriptions are durable'; END IF;
  IF OLD.root_recording_id IS DISTINCT FROM NEW.root_recording_id OR OLD.account_recording_id IS DISTINCT FROM NEW.account_recording_id OR OLD.identifier IS DISTINCT FROM NEW.identifier OR OLD.provider_reference IS DISTINCT FROM NEW.provider_reference THEN RAISE EXCEPTION 'subscription authority is immutable'; END IF;
  IF NOT ((OLD.state = 'trialing' AND NEW.state IN ('active', 'paused', 'cancelled', 'expired')) OR (OLD.state = 'active' AND NEW.state IN ('past_due', 'paused', 'cancelled', 'expired')) OR (OLD.state = 'past_due' AND NEW.state IN ('active', 'paused', 'cancelled', 'expired')) OR (OLD.state = 'paused' AND NEW.state IN ('active', 'cancelled', 'expired')) OR (OLD.state = 'cancelled' AND NEW.state = 'active') OR OLD.state = NEW.state) THEN RAISE EXCEPTION 'subscription lifecycle transition is invalid'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_checkout_attempt_command_correlation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_checkout_attempt_command_correlation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.financial_command_attempt_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM recording_studio_billing_financial_command_attempts command_attempt
    WHERE command_attempt.id = NEW.financial_command_attempt_id
      AND command_attempt.financial_command_id = NEW.financial_command_id
      AND command_attempt.attempt_number = NEW.attempt_number
  ) THEN
    RAISE EXCEPTION 'checkout attempt must match its financial command attempt';
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_checkout_authority(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_checkout_authority() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM recording_studio_recordings root WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL) THEN
    RAISE EXCEPTION 'checkout intent root authority is invalid';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM recording_studio_recordings account_recording JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id WHERE account_recording.id = NEW.account_recording_id AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = NEW.root_recording_id AND account_recording.parent_recording_id = NEW.root_recording_id AND account_recording.trashed_at IS NULL AND account.root_recording_id = NEW.root_recording_id) THEN
    RAISE EXCEPTION 'checkout intent account authority is invalid';
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_checkout_command_binding(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_checkout_command_binding() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.financial_command_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM recording_studio_billing_checkout_intent_items item
    JOIN recording_studio_billing_financial_commands command ON command.id = NEW.financial_command_id
    WHERE item.checkout_intent_id = NEW.id
      AND NOT (command.canonical_request -> 'authority' -> 'commercial_manifest_digests' ? item.manifest_digest)
  ) THEN
    RAISE EXCEPTION 'checkout command must bind every frozen manifest digest';
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_checkout_execution_state(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_checkout_execution_state() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.state IN ('requires_requote', 'requires_review', 'cancelled', 'expired') AND EXISTS (
    SELECT 1 FROM recording_studio_billing_financial_commands command
    WHERE command.id = NEW.financial_command_id AND command.state IN ('pending', 'processing')
  ) THEN
    RAISE EXCEPTION 'non-executable checkout intent cannot retain an executable command';
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_command_attempt_consistency(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_command_attempt_consistency() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE command_uuid uuid;
DECLARE command_state text;
DECLARE open_attempts integer;
DECLARE trigger_row jsonb;
BEGIN
  trigger_row := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  command_uuid := (trigger_row ->> CASE
    WHEN TG_TABLE_NAME = 'recording_studio_billing_financial_commands' THEN 'id'
    ELSE 'financial_command_id'
  END)::uuid;
  SELECT state INTO command_state
  FROM recording_studio_billing_financial_commands
  WHERE id = command_uuid;
  IF command_state IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT COUNT(*) INTO open_attempts
  FROM recording_studio_billing_financial_command_attempts
  WHERE financial_command_id = command_uuid
    AND state = 'processing' AND completed_at IS NULL;
  IF (command_state = 'processing' AND open_attempts <> 1)
     OR (command_state <> 'processing' AND open_attempts <> 0) THEN
    RAISE EXCEPTION 'financial command and attempt lifecycle is inconsistent';
  END IF;
  RETURN NULL;
END;
$$;

-- Name: rs_billing_validate_command_authority(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_command_authority() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NOT (NEW.state = 'processing' AND OLD.state IS DISTINCT FROM NEW.state) THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM recording_studio_recordings root
    WHERE root.id = NEW.root_recording_id
      AND root.parent_recording_id IS NULL
      AND root.root_recording_id = root.id
      AND root.trashed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'financial command root authority is invalid';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM recording_studio_recordings account_recording
    JOIN recording_studio_billing_accounts account
      ON account.id = account_recording.recordable_id
    WHERE account_recording.id = NEW.account_recording_id
      AND account_recording.recordable_type = 'RecordingStudioBilling::Account'
      AND account_recording.root_recording_id = NEW.root_recording_id
      AND account_recording.parent_recording_id = NEW.root_recording_id
      AND account_recording.trashed_at IS NULL
      AND account.root_recording_id = NEW.root_recording_id
  ) THEN
    RAISE EXCEPTION 'financial command account authority is invalid';
  END IF;
  IF NEW.provider_account_recording_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM recording_studio_recordings provider_recording
    JOIN recording_studio_billing_provider_accounts provider
      ON provider.id = provider_recording.recordable_id
    JOIN recording_studio_recordings admin_recording
      ON admin_recording.id = provider.billing_admin_recording_id
    JOIN recording_studio_billing_billing_admins admin
      ON admin.id = admin_recording.recordable_id
    WHERE provider_recording.id = NEW.provider_account_recording_id
      AND provider_recording.recordable_type = 'RecordingStudioBilling::ProviderAccount'
      AND provider_recording.parent_recording_id = admin_recording.id
      AND provider_recording.root_recording_id = admin_recording.root_recording_id
      AND provider_recording.trashed_at IS NULL
      AND provider.adapter_key = NEW.provider_adapter_key
      AND admin_recording.recordable_type = 'RecordingStudioBilling::BillingAdmin'
      AND admin_recording.trashed_at IS NULL
      AND admin.root_recording_id = admin_recording.root_recording_id
  ) THEN
    RAISE EXCEPTION 'financial command provider authority is invalid';
  END IF;
  IF NOT rs_billing_safe_financial_json(NEW.canonical_request -> 'request')
     OR NOT rs_billing_safe_financial_json(NEW.normalized_result)
     OR NOT rs_billing_safe_financial_json(NEW.safe_error_details)
     OR NEW.provider_reference ~* '^[[:space:]]*(https?|ftp)://' THEN
    RAISE EXCEPTION 'financial command contains unsafe persisted data';
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_commercial_lifecycle_authority(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_commercial_lifecycle_authority() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_TABLE_NAME = 'recording_studio_billing_subscription_items' THEN
    IF NOT EXISTS (
      SELECT 1 FROM recording_studio_billing_subscriptions subscription
      WHERE subscription.id = NEW.subscription_id AND subscription.root_recording_id = NEW.root_recording_id
        AND subscription.account_recording_id = NEW.account_recording_id
    ) THEN RAISE EXCEPTION 'subscription item authority is invalid'; END IF;
  ELSIF TG_TABLE_NAME = 'recording_studio_billing_subscription_item_versions' THEN
    IF NOT EXISTS (
      SELECT 1 FROM recording_studio_billing_subscription_items item
      WHERE item.id = NEW.subscription_item_id AND item.subscription_id = NEW.subscription_id
        AND item.root_recording_id = NEW.root_recording_id AND item.account_recording_id = NEW.account_recording_id
        AND item.line_key = NEW.line_key
    ) THEN RAISE EXCEPTION 'subscription item version authority is invalid'; END IF;
  ELSIF TG_TABLE_NAME = 'recording_studio_billing_subscription_change_intents' THEN
    IF NOT EXISTS (
      SELECT 1 FROM recording_studio_billing_subscriptions subscription
      WHERE subscription.id = NEW.subscription_id AND subscription.root_recording_id = NEW.root_recording_id
        AND subscription.account_recording_id = NEW.account_recording_id
    ) THEN RAISE EXCEPTION 'subscription change authority is invalid'; END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_commercial_publication(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_commercial_publication() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_ARGV[0] = 'RecordingStudioBilling::FeatureOverride' THEN
    IF EXISTS (
      SELECT 1
      FROM recording_studio_recordings AS recording
      INNER JOIN recording_studio_events AS creation
        ON creation.recording_id = recording.id
       AND creation.action = 'created'
       AND creation.recordable_type = TG_ARGV[0]
       AND creation.recordable_id = NEW.id
      WHERE recording.recordable_type = TG_ARGV[0]
        AND recording.recordable_id = NEW.id
    ) OR (
      current_setting('recording_studio_billing.authorized_feature_override', true) = 'on' AND EXISTS (
      SELECT 1
      FROM recording_studio_recordings AS recording
      INNER JOIN recording_studio_events AS revision
        ON revision.recording_id = recording.id
       AND revision.action = 'updated'
       AND revision.recordable_type = TG_ARGV[0]
       AND revision.recordable_id = NEW.id
       AND revision.actor_type IS NOT NULL
       AND revision.actor_id IS NOT NULL
      WHERE recording.recordable_type = TG_ARGV[0]
        AND recording.recordable_id = NEW.id
      )
    ) THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'feature override revision is missing its actor-attributed event';
  END IF;
  IF NEW.state = 'draft' THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM recording_studio_recordings AS recording
    INNER JOIN recording_studio_events AS revision
      ON revision.recording_id = recording.id
     AND revision.action = 'updated'
     AND revision.recordable_type = TG_ARGV[0]
     AND revision.recordable_id = NEW.id
     AND revision.actor_type IS NOT NULL
     AND revision.actor_id IS NOT NULL
    INNER JOIN recording_studio_billing_commercial_publication_candidates AS candidate
      ON candidate.candidate_digest = revision.metadata ->> 'commercial_candidate_digest'
     AND candidate.root_recording_id = recording.root_recording_id
     AND candidate.activated_at IS NOT NULL
    INNER JOIN recording_studio_events AS publication_event
      ON publication_event.recording_id = recording.id
     AND publication_event.action = 'commercial_published'
     AND publication_event.metadata ->> 'candidate_digest' = candidate.candidate_digest
     AND publication_event.actor_type = revision.actor_type
     AND publication_event.actor_id = revision.actor_id
    WHERE recording.recordable_type = TG_ARGV[0]
      AND recording.recordable_id = NEW.id
  ) THEN
    RAISE EXCEPTION 'commercial publication is missing its authorized transaction artifacts';
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_financial_lifecycle_authority(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_financial_lifecycle_authority() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE reserved_amount bigint;
BEGIN
  IF TG_TABLE_NAME = 'recording_studio_billing_payments' THEN
    IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_financial_commands command WHERE command.id = NEW.financial_command_id AND command.root_recording_id = NEW.root_recording_id AND command.account_recording_id = NEW.account_recording_id) THEN RAISE EXCEPTION 'payment command authority is invalid'; END IF;
  ELSIF TG_TABLE_NAME = 'recording_studio_billing_invoices' THEN
    IF NEW.financial_command_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM recording_studio_billing_financial_commands command WHERE command.id = NEW.financial_command_id AND command.root_recording_id = NEW.root_recording_id AND command.account_recording_id = NEW.account_recording_id) THEN RAISE EXCEPTION 'invoice command authority is invalid'; END IF;
  ELSIF TG_TABLE_NAME = 'recording_studio_billing_payment_allocations' THEN
    PERFORM 1 FROM recording_studio_billing_payments WHERE id = NEW.payment_id FOR UPDATE;
    IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_payments payment JOIN recording_studio_billing_invoices invoice ON invoice.id = NEW.invoice_id WHERE payment.id = NEW.payment_id AND payment.root_recording_id = invoice.root_recording_id AND payment.account_recording_id = invoice.account_recording_id) OR NEW.amount_minor + COALESCE((SELECT SUM(amount_minor) FROM recording_studio_billing_payment_allocations WHERE payment_id = NEW.payment_id AND id IS DISTINCT FROM NEW.id), 0) > (SELECT amount_minor FROM recording_studio_billing_payments WHERE id = NEW.payment_id) THEN RAISE EXCEPTION 'payment allocation authority is invalid'; END IF;
  ELSIF TG_TABLE_NAME = 'recording_studio_billing_refund_intents' THEN
    PERFORM 1 FROM recording_studio_billing_payments WHERE id = NEW.payment_id FOR UPDATE;
    IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_payments payment WHERE payment.id = NEW.payment_id AND payment.root_recording_id = NEW.root_recording_id AND payment.account_recording_id = NEW.account_recording_id AND payment.currency_code = NEW.currency_code) OR NEW.amount_minor + COALESCE((SELECT SUM(amount_minor) FROM recording_studio_billing_refund_intents WHERE payment_id = NEW.payment_id AND state IN ('pending', 'executing', 'completed') AND id IS DISTINCT FROM NEW.id), 0) > (SELECT amount_minor FROM recording_studio_billing_payments WHERE id = NEW.payment_id) THEN RAISE EXCEPTION 'refund authority is invalid'; END IF;
  ELSIF TG_TABLE_NAME = 'recording_studio_billing_adjustment_intents' THEN
    PERFORM 1 FROM recording_studio_billing_invoices WHERE id = NEW.invoice_id FOR UPDATE;
    IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_invoices invoice WHERE invoice.id = NEW.invoice_id AND invoice.root_recording_id = NEW.root_recording_id AND invoice.account_recording_id = NEW.account_recording_id AND invoice.currency_code = NEW.currency_code) THEN RAISE EXCEPTION 'adjustment authority is invalid'; END IF;
    IF NEW.kind IN ('credit', 'write_off') AND NEW.amount_minor + COALESCE((SELECT SUM(amount_minor) FROM recording_studio_billing_adjustment_intents WHERE invoice_id = NEW.invoice_id AND kind IN ('credit', 'write_off') AND state IN ('pending', 'executing', 'completed') AND id IS DISTINCT FROM NEW.id), 0) > (SELECT total_minor FROM recording_studio_billing_invoices WHERE id = NEW.invoice_id) THEN RAISE EXCEPTION 'adjustment capacity is invalid'; END IF;
  ELSIF TG_TABLE_NAME = 'recording_studio_billing_refunds' THEN
    IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_refund_intents intent JOIN recording_studio_billing_payments payment ON payment.id = intent.payment_id WHERE intent.id = NEW.refund_intent_id AND payment.id = NEW.payment_id AND intent.financial_command_id = NEW.financial_command_id AND intent.amount_minor = NEW.amount_minor AND intent.currency_code = NEW.currency_code) THEN RAISE EXCEPTION 'refund projection authority is invalid'; END IF;
  ELSIF TG_TABLE_NAME = 'recording_studio_billing_financial_adjustments' THEN
    IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_adjustment_intents intent WHERE intent.id = NEW.adjustment_intent_id AND intent.invoice_id = NEW.invoice_id AND intent.financial_command_id = NEW.financial_command_id AND intent.kind = NEW.kind AND intent.amount_minor = NEW.amount_minor AND intent.currency_code = NEW.currency_code) THEN RAISE EXCEPTION 'adjustment projection authority is invalid'; END IF;
  ELSIF TG_TABLE_NAME = 'recording_studio_billing_plan_update_applications' THEN
    IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_plan_update_runs run JOIN recording_studio_billing_subscription_change_intents change ON change.id = NEW.subscription_change_intent_id WHERE run.id = NEW.plan_update_run_id AND run.plan_update_id = NEW.plan_update_id AND change.subscription_id = NEW.subscription_id) THEN RAISE EXCEPTION 'plan update application authority is invalid'; END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_lifecycle_projection(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_lifecycle_projection() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM recording_studio_recordings root
    JOIN recording_studio_recordings account_recording ON account_recording.id = NEW.account_recording_id
    JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
    WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL
      AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = root.id AND account_recording.parent_recording_id = root.id AND account_recording.trashed_at IS NULL AND account.root_recording_id = root.id
  ) THEN RAISE EXCEPTION 'lifecycle root or account authority is invalid'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_provider_reference(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_provider_reference() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'provider references are append-only'; END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM recording_studio_recordings provider_recording
    JOIN recording_studio_billing_provider_accounts provider ON provider.id = provider_recording.recordable_id
    JOIN recording_studio_billing_financial_commands command ON command.id = NEW.financial_command_id
    WHERE provider_recording.id = NEW.provider_account_recording_id
      AND provider_recording.recordable_type = 'RecordingStudioBilling::ProviderAccount'
      AND command.provider_account_recording_id = NEW.provider_account_recording_id
      AND command.provider_adapter_key = NEW.provider_adapter_key
      AND provider.adapter_key = NEW.provider_adapter_key
      AND provider.environment = NEW.environment
  ) THEN RAISE EXCEPTION 'provider reference authority is invalid'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_tax_authority(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_tax_authority() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  command_row recording_studio_billing_financial_commands%ROWTYPE;
  command_request jsonb;
  command_result jsonb;
  command_metadata jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM recording_studio_recordings root WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL) THEN RAISE EXCEPTION 'tax root authority is invalid'; END IF;
  IF NOT EXISTS (SELECT 1 FROM recording_studio_recordings account_recording JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id WHERE account_recording.id = NEW.account_recording_id AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = NEW.root_recording_id AND account_recording.parent_recording_id = NEW.root_recording_id AND account_recording.trashed_at IS NULL AND account.root_recording_id = NEW.root_recording_id) THEN RAISE EXCEPTION 'tax account authority is invalid'; END IF;
  SELECT * INTO command_row FROM recording_studio_billing_financial_commands WHERE id = NEW.financial_command_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'tax command authority is invalid'; END IF;
  command_request := command_row.canonical_request -> 'request'; command_result := command_row.normalized_result;
  SELECT safe_metadata INTO command_metadata FROM recording_studio_billing_financial_command_attempts WHERE financial_command_id = NEW.financial_command_id AND completed_at IS NOT NULL ORDER BY attempt_number DESC LIMIT 1;
  IF command_row.command_type = 'tax_calculation' THEN
    IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_commercial_manifests manifest WHERE manifest.id = NEW.commercial_manifest_id AND manifest.root_recording_id = NEW.root_recording_id AND manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL) THEN RAISE EXCEPTION 'tax manifest authority is invalid'; END IF;
    IF command_row.root_recording_id IS DISTINCT FROM NEW.root_recording_id OR command_row.account_recording_id IS DISTINCT FROM NEW.account_recording_id OR command_row.calculator_key IS DISTINCT FROM NEW.calculator_key OR command_row.calculator_mode IS DISTINCT FROM NEW.calculator_mode THEN RAISE EXCEPTION 'tax command authority is invalid'; END IF;
    IF command_request ->> 'commercial_manifest_id' IS DISTINCT FROM NEW.commercial_manifest_id::text OR command_request ->> 'commercial_manifest_digest' IS DISTINCT FROM NEW.manifest_digest OR command_request ->> 'transaction_type' IS DISTINCT FROM NEW.transaction_type OR command_request ->> 'operation_reference' IS DISTINCT FROM NEW.operation_reference OR command_request ->> 'idempotency_key' IS DISTINCT FROM NEW.idempotency_key OR (command_request ->> 'subtotal_minor')::bigint IS DISTINCT FROM NEW.subtotal_minor OR (command_request ->> 'discount_minor')::bigint IS DISTINCT FROM NEW.discount_minor OR command_request ->> 'currency' IS DISTINCT FROM NEW.currency OR command_result ->> 'request_fingerprint' IS DISTINCT FROM NEW.request_fingerprint OR command_result ->> 'status' IS DISTINCT FROM NEW.status OR (command_result ->> 'subtotal_minor')::bigint IS DISTINCT FROM NEW.subtotal_minor OR (command_result ->> 'discount_minor')::bigint IS DISTINCT FROM NEW.discount_minor OR (command_result ->> 'tax_minor')::bigint IS DISTINCT FROM NEW.tax_minor OR (command_result ->> 'total_minor')::bigint IS DISTINCT FROM NEW.total_minor OR command_result ->> 'currency' IS DISTINCT FROM NEW.currency OR command_result ->> 'behavior' IS DISTINCT FROM NEW.behavior OR command_result -> 'breakdown' IS DISTINCT FROM NEW.breakdown OR command_result ->> 'calculator_reference' IS DISTINCT FROM NEW.calculator_reference OR (command_result ->> 'calculated_at')::timestamptz IS DISTINCT FROM NEW.calculated_at OR command_metadata IS DISTINCT FROM NEW.safe_metadata THEN RAISE EXCEPTION 'tax calculation does not match its durable command'; END IF;
  ELSIF command_row.command_type = 'checkout' THEN
    IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_commercial_manifests manifest JOIN recording_studio_recordings provider_recording ON provider_recording.id = command_row.provider_account_recording_id JOIN recording_studio_billing_provider_accounts provider ON provider.id = provider_recording.recordable_id JOIN recording_studio_recordings billing_admin ON billing_admin.id = provider.billing_admin_recording_id WHERE manifest.id = NEW.commercial_manifest_id AND manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL AND provider_recording.recordable_type = 'RecordingStudioBilling::ProviderAccount' AND provider_recording.parent_recording_id = billing_admin.id AND manifest.root_recording_id = billing_admin.root_recording_id AND provider.adapter_key = command_row.provider_adapter_key AND manifest.recording_snapshots @> jsonb_build_array(jsonb_build_object('recording_id', provider_recording.id))) THEN RAISE EXCEPTION 'native checkout tax manifest authority is invalid'; END IF;
    IF command_row.state <> 'succeeded' OR command_row.root_recording_id IS DISTINCT FROM NEW.root_recording_id OR command_row.account_recording_id IS DISTINCT FROM NEW.account_recording_id OR command_request #>> '{tax,enabled}' IS DISTINCT FROM 'true' OR command_request #>> '{tax,mode}' IS DISTINCT FROM 'provider_native' OR command_request #>> '{tax,calculator_key}' IS DISTINCT FROM NEW.calculator_key OR NEW.calculator_mode <> 'provider_calculation' OR command_request #>> '{tax,behavior}' IS DISTINCT FROM NEW.behavior OR jsonb_typeof(command_request #> '{tax,semantic_categories}') IS DISTINCT FROM 'array' OR jsonb_typeof(command_request #> '{tax,location_requirements}') IS DISTINCT FROM 'array' OR NOT (command_row.canonical_request -> 'authority' -> 'commercial_manifest_digests' ? NEW.manifest_digest) OR NEW.revision_number <> 1 OR NEW.supersedes_id IS NOT NULL OR command_result ->> 'authority' IS DISTINCT FROM 'verified_webhook' OR jsonb_typeof(command_result -> 'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(command_result -> 'lines') = 0 OR NEW.operation_reference IS DISTINCT FROM command_row.operation_id::text OR NEW.idempotency_key IS DISTINCT FROM command_row.provider_idempotency_key OR NEW.request_fingerprint IS DISTINCT FROM command_row.request_fingerprint OR (command_result ->> 'subtotal_minor')::bigint IS DISTINCT FROM NEW.subtotal_minor OR (command_result ->> 'discount_minor')::bigint IS DISTINCT FROM NEW.discount_minor OR (command_result ->> 'tax_minor')::bigint IS DISTINCT FROM NEW.tax_minor OR (command_result ->> 'total_minor')::bigint IS DISTINCT FROM NEW.total_minor OR command_result ->> 'currency' IS DISTINCT FROM NEW.currency OR command_result ->> 'behavior' IS DISTINCT FROM NEW.behavior OR command_result -> 'breakdown' IS DISTINCT FROM NEW.breakdown OR command_result ->> 'calculator_reference' IS DISTINCT FROM NEW.calculator_reference OR (command_result ->> 'calculated_at')::timestamptz IS DISTINCT FROM NEW.calculated_at OR command_metadata IS DISTINCT FROM NEW.safe_metadata THEN RAISE EXCEPTION 'native checkout tax does not match the verified provider result'; END IF;
  ELSE RAISE EXCEPTION 'tax command authority is invalid'; END IF;
  IF NOT rs_billing_safe_financial_json(NEW.breakdown) OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) OR NEW.operation_reference ~* '^[[:space:]]*(https?|ftp)://' OR NEW.calculator_reference ~* '^[[:space:]]*(https?|ftp)://' THEN RAISE EXCEPTION 'tax calculation contains unsafe persisted data'; END IF;
  IF NEW.revision_number > 1 AND NOT EXISTS (SELECT 1 FROM recording_studio_billing_tax_calculations previous WHERE previous.id = NEW.supersedes_id AND previous.financial_command_id = NEW.financial_command_id AND previous.revision_number = NEW.revision_number - 1 AND previous.root_recording_id = NEW.root_recording_id AND previous.idempotency_key = NEW.idempotency_key AND previous.calculator_key = NEW.calculator_key AND previous.calculator_mode = NEW.calculator_mode AND previous.request_fingerprint = NEW.request_fingerprint) THEN RAISE EXCEPTION 'tax calculation revision history is invalid'; END IF;
  RETURN NEW;
END;
$$;

-- Name: rs_billing_validate_tax_manifest_set(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_tax_manifest_set() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  command_row recording_studio_billing_financial_commands%ROWTYPE;
BEGIN
  IF NOT rs_billing_sorted_manifest_set(NEW.manifest_digests, NEW.manifest_digest) THEN
    RAISE EXCEPTION 'tax calculation manifest set is invalid';
  END IF;

  SELECT * INTO command_row
  FROM recording_studio_billing_financial_commands
  WHERE id = NEW.financial_command_id;

  IF command_row.command_type = 'tax_calculation'
     AND NEW.manifest_digests IS DISTINCT FROM jsonb_build_array(NEW.manifest_digest) THEN
    RAISE EXCEPTION 'tax calculation manifest set is invalid';
  END IF;

  IF command_row.command_type = 'checkout'
     AND NEW.manifest_digests IS DISTINCT FROM command_row.canonical_request -> 'authority' -> 'commercial_manifest_digests' THEN
    RAISE EXCEPTION 'native checkout tax manifest set authority is invalid';
  END IF;

  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

-- Name: recording_studio_billing_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    root_recording_id uuid NOT NULL,
    contact_email character varying,
    billing_country_code character varying(2),
    billing_currency_code character varying(3),
    locale character varying(16),
    time_zone character varying(64),
    tax_location_country_code character varying(2),
    tax_location_region_code character varying(16),
    tax_location_postal_code character varying(32)
);

-- Name: recording_studio_billing_adjustment_intents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_adjustment_intents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    invoice_id uuid NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    financial_command_id uuid,
    local_idempotency_key character varying NOT NULL,
    state character varying DEFAULT 'pending'::character varying NOT NULL,
    kind character varying NOT NULL,
    amount_minor bigint NOT NULL,
    currency_code character varying NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    request_fingerprint character varying,
    reason character varying,
    actor_reference character varying,
    tax_treatment character varying DEFAULT 'provider_default'::character varying NOT NULL,
    approved_authority jsonb DEFAULT '{}'::jsonb NOT NULL,
    affected_reference jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT rs_billing_adjustment_intent_kind CHECK ((((kind)::text = ANY (ARRAY[('credit'::character varying)::text, ('debit'::character varying)::text, ('write_off'::character varying)::text])) AND (amount_minor > 0)))
);

-- Name: recording_studio_billing_billing_admins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_billing_admins (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    root_recording_id uuid NOT NULL
);

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
    CONSTRAINT recording_studio_billing_billing_options_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_options_checkout_policy CHECK (((checkout_policy)::text = ANY (ARRAY[('allowed'::character varying)::text, ('required'::character varying)::text, ('disabled'::character varying)::text]))),
    CONSTRAINT rs_billing_options_collection_method CHECK (((collection_method)::text = ANY (ARRAY[('automatic'::character varying)::text, ('send_invoice'::character varying)::text]))),
    CONSTRAINT rs_billing_options_default_maximum CHECK (((maximum_quantity IS NULL) OR (default_quantity <= maximum_quantity))),
    CONSTRAINT rs_billing_options_default_minimum CHECK (((minimum_quantity IS NULL) OR (default_quantity >= minimum_quantity))),
    CONSTRAINT rs_billing_options_default_quantity CHECK ((default_quantity > 0)),
    CONSTRAINT rs_billing_options_interval CHECK (((("interval")::text = ANY (ARRAY[('day'::character varying)::text, ('week'::character varying)::text, ('month'::character varying)::text, ('year'::character varying)::text])) OR ("interval" IS NULL))),
    CONSTRAINT rs_billing_options_interval_count CHECK (((interval_count > 0) OR (interval_count IS NULL))),
    CONSTRAINT rs_billing_options_lifecycle_policy CHECK (((lifecycle_policy)::text = ANY (ARRAY[('immediate'::character varying)::text, ('scheduled'::character varying)::text]))),
    CONSTRAINT rs_billing_options_maximum_quantity CHECK (((maximum_quantity > 0) OR (maximum_quantity IS NULL))),
    CONSTRAINT rs_billing_options_minimum_quantity CHECK (((minimum_quantity >= 0) OR (minimum_quantity IS NULL))),
    CONSTRAINT rs_billing_options_payment_terms_days CHECK ((payment_terms_days >= 0)),
    CONSTRAINT rs_billing_options_pricing_model CHECK (((pricing_model)::text = ANY (ARRAY[('flat'::character varying)::text, ('per_unit'::character varying)::text, ('package'::character varying)::text]))),
    CONSTRAINT rs_billing_options_proration_policy CHECK (((proration_policy)::text = ANY (ARRAY[('none'::character varying)::text, ('prorate'::character varying)::text]))),
    CONSTRAINT rs_billing_options_quantity_bounds CHECK (((minimum_quantity IS NULL) OR (maximum_quantity IS NULL) OR (minimum_quantity <= maximum_quantity))),
    CONSTRAINT rs_billing_options_quantity_mode CHECK (((quantity_mode)::text = ANY (ARRAY[('fixed'::character varying)::text, ('adjustable'::character varying)::text]))),
    CONSTRAINT rs_billing_options_recurrence CHECK (((recurrence)::text = ANY (ARRAY[('one_time'::character varying)::text, ('recurring'::character varying)::text]))),
    CONSTRAINT rs_billing_options_tax_policy CHECK (((tax_policy)::text = ANY (ARRAY[('exclusive'::character varying)::text, ('inclusive'::character varying)::text, ('provider_default'::character varying)::text]))),
    CONSTRAINT rs_billing_options_trial_days CHECK ((trial_days >= 0))
);

-- Name: recording_studio_billing_checkout_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_checkout_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    checkout_intent_id uuid NOT NULL,
    financial_command_id uuid NOT NULL,
    attempt_number integer NOT NULL,
    state character varying NOT NULL,
    safe_result jsonb DEFAULT '{}'::jsonb NOT NULL,
    safe_error_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    financial_command_attempt_id uuid,
    CONSTRAINT rs_billing_checkout_attempts_error_object CHECK ((jsonb_typeof(safe_error_details) = 'object'::text)),
    CONSTRAINT rs_billing_checkout_attempts_lifecycle CHECK (((((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('processing'::character varying)::text])) AND (completed_at IS NULL)) OR (((state)::text = ANY (ARRAY[('succeeded'::character varying)::text, ('failed'::character varying)::text, ('cancelled'::character varying)::text, ('unknown'::character varying)::text])) AND (completed_at IS NOT NULL)))),
    CONSTRAINT rs_billing_checkout_attempts_number CHECK ((attempt_number > 0)),
    CONSTRAINT rs_billing_checkout_attempts_result_object CHECK ((jsonb_typeof(safe_result) = 'object'::text)),
    CONSTRAINT rs_billing_checkout_attempts_state CHECK (((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('processing'::character varying)::text, ('succeeded'::character varying)::text, ('failed'::character varying)::text, ('cancelled'::character varying)::text, ('unknown'::character varying)::text])))
);

-- Name: recording_studio_billing_checkout_intent_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_checkout_intent_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    checkout_intent_id uuid NOT NULL,
    product_recording_id uuid NOT NULL,
    billing_option_recording_id uuid NOT NULL,
    price_recording_id uuid NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    market_recording_id uuid NOT NULL,
    product_recordable_type character varying NOT NULL,
    product_recordable_id uuid NOT NULL,
    billing_option_recordable_type character varying NOT NULL,
    billing_option_recordable_id uuid NOT NULL,
    quantity integer NOT NULL,
    currency_code character varying NOT NULL,
    collection_method character varying NOT NULL,
    presentation character varying NOT NULL,
    commercial_manifest jsonb NOT NULL,
    manifest_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_checkout_items_currency CHECK (((currency_code)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT rs_billing_checkout_items_digest CHECK (((manifest_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_checkout_items_manifest_object CHECK ((jsonb_typeof(commercial_manifest) = 'object'::text)),
    CONSTRAINT rs_billing_checkout_items_presentation CHECK (((presentation)::text = ANY (ARRAY[('embedded'::character varying)::text, ('redirect'::character varying)::text, ('payment_link'::character varying)::text, ('invoice'::character varying)::text, ('no_charge'::character varying)::text]))),
    CONSTRAINT rs_billing_checkout_items_quantity CHECK ((quantity > 0))
);

-- Name: recording_studio_billing_checkout_intents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_checkout_intents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    local_idempotency_key character varying NOT NULL,
    request_fingerprint character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    advisory_country_code character varying,
    advisory_currency_code character varying,
    presentation_preference character varying,
    financial_command_id uuid,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_checkout_intents_fingerprint CHECK (((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_checkout_intents_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('validated'::character varying)::text, ('awaiting_confirmation'::character varying)::text, ('pending_provider'::character varying)::text, ('requires_requote'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text, ('cancelled'::character varying)::text, ('expired'::character varying)::text, ('requires_review'::character varying)::text])))
);

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

-- Name: recording_studio_billing_cost_cards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_cost_cards (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_studio_billing_cost_cards_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
);

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
    CONSTRAINT recording_studio_billing_cost_rates_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
);

-- Name: recording_studio_billing_credit_ledger_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_credit_ledger_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    purchase_effect_id uuid,
    product_recording_id uuid NOT NULL,
    manifest_digest character varying NOT NULL,
    credit_key character varying NOT NULL,
    amount bigint NOT NULL,
    effective_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    direction character varying DEFAULT 'credit'::character varying NOT NULL,
    usage_event_id uuid,
    idempotency_key character varying,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT rs_billing_credit_ledger_digest CHECK (((manifest_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_credit_ledger_direction CHECK (((direction)::text = ANY (ARRAY[('credit'::character varying)::text, ('debit'::character varying)::text]))),
    CONSTRAINT rs_billing_credit_ledger_direction_amount CHECK (((((direction)::text = 'credit'::text) AND (amount > 0) AND (purchase_effect_id IS NOT NULL) AND (usage_event_id IS NULL) AND (idempotency_key IS NULL)) OR (((direction)::text = 'debit'::text) AND (amount < 0) AND (purchase_effect_id IS NULL) AND (usage_event_id IS NOT NULL) AND (idempotency_key IS NOT NULL)))),
    CONSTRAINT rs_billing_credit_ledger_metadata_object CHECK ((jsonb_typeof(safe_metadata) = 'object'::text))
);

-- Name: recording_studio_billing_entitlement_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_entitlement_grants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    source_type character varying NOT NULL,
    source_id uuid NOT NULL,
    manifest_digest character varying NOT NULL,
    feature_key character varying NOT NULL,
    feature_kind character varying NOT NULL,
    merge_rule character varying NOT NULL,
    value jsonb NOT NULL,
    projected_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_entitlement_grant_digest CHECK (((manifest_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_entitlement_grant_feature_kind CHECK (((feature_kind)::text = ANY (ARRAY[('boolean'::character varying)::text, ('limit'::character varying)::text, ('allowance'::character varying)::text, ('variant'::character varying)::text]))),
    CONSTRAINT rs_billing_entitlement_grant_merge_rule CHECK (((merge_rule)::text = ANY (ARRAY[('replace'::character varying)::text, ('minimum'::character varying)::text, ('maximum'::character varying)::text, ('merge'::character varying)::text, ('append'::character varying)::text]))),
    CONSTRAINT rs_billing_entitlement_grant_source_type CHECK (((source_type)::text = ANY (ARRAY[('RecordingStudioBilling::SubscriptionItemVersion'::character varying)::text, ('RecordingStudioBilling::PurchaseEffect'::character varying)::text]))),
    CONSTRAINT rs_billing_entitlement_grant_value CHECK ((jsonb_typeof(value) IS NOT NULL))
);

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
    CONSTRAINT recording_studio_billing_feature_overrides_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
);

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
    CONSTRAINT recording_studio_billing_features_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_features_kind CHECK (((kind)::text = ANY (ARRAY[('boolean'::character varying)::text, ('limit'::character varying)::text, ('allowance'::character varying)::text, ('variant'::character varying)::text])))
);

-- Name: recording_studio_billing_financial_adjustments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_financial_adjustments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    adjustment_intent_id uuid NOT NULL,
    invoice_id uuid NOT NULL,
    financial_command_id uuid NOT NULL,
    kind character varying NOT NULL,
    amount_minor bigint NOT NULL,
    currency_code character varying NOT NULL,
    recorded_at timestamp(6) without time zone NOT NULL,
    safe_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

-- Name: recording_studio_billing_financial_command_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_financial_command_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    financial_command_id uuid NOT NULL,
    attempt_number integer NOT NULL,
    state character varying NOT NULL,
    provider_idempotency_key character varying NOT NULL,
    started_at timestamp(6) without time zone NOT NULL,
    completed_at timestamp(6) without time zone,
    normalized_result jsonb DEFAULT '{}'::jsonb NOT NULL,
    safe_error_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    uncertain_outcome boolean DEFAULT false NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_command_attempts_lifecycle CHECK (((((state)::text = 'processing'::text) AND (completed_at IS NULL)) OR (((state)::text = ANY (ARRAY[('succeeded'::character varying)::text, ('failed'::character varying)::text, ('uncertain'::character varying)::text, ('requires_reconciliation'::character varying)::text, ('cancelled'::character varying)::text])) AND (completed_at IS NOT NULL)))),
    CONSTRAINT rs_billing_command_attempts_normalized_result_object CHECK ((jsonb_typeof(normalized_result) = 'object'::text)),
    CONSTRAINT rs_billing_command_attempts_positive_number CHECK ((attempt_number > 0)),
    CONSTRAINT rs_billing_command_attempts_safe_error_details_object CHECK ((jsonb_typeof(safe_error_details) = 'object'::text)),
    CONSTRAINT rs_billing_command_attempts_safe_metadata_object CHECK ((jsonb_typeof(safe_metadata) = 'object'::text)),
    CONSTRAINT rs_billing_command_attempts_state CHECK (((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('processing'::character varying)::text, ('succeeded'::character varying)::text, ('failed'::character varying)::text, ('uncertain'::character varying)::text, ('requires_reconciliation'::character varying)::text, ('cancelled'::character varying)::text]))),
    CONSTRAINT rs_billing_command_attempts_times CHECK (((completed_at IS NULL) OR (completed_at >= started_at)))
);

-- Name: recording_studio_billing_financial_commands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_financial_commands (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    operation_id uuid DEFAULT gen_random_uuid() NOT NULL,
    command_type character varying NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    provider_account_recording_id uuid,
    provider_adapter_key character varying,
    calculator_key character varying,
    calculator_mode character varying,
    canonical_request jsonb NOT NULL,
    request_fingerprint character varying NOT NULL,
    local_idempotency_key character varying NOT NULL,
    provider_idempotency_key character varying NOT NULL,
    state character varying DEFAULT 'pending'::character varying NOT NULL,
    provider_reference character varying,
    normalized_result jsonb DEFAULT '{}'::jsonb NOT NULL,
    safe_error_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    reconciliation_state character varying DEFAULT 'not_required'::character varying NOT NULL,
    claim_token uuid,
    claimed_at timestamp(6) without time zone,
    lease_expires_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_commands_calculator_key CHECK (((calculator_key IS NULL) OR ((calculator_key)::text ~ '^[a-z][a-z0-9_]*$'::text))),
    CONSTRAINT rs_billing_commands_calculator_mode CHECK (((calculator_mode IS NULL) OR ((calculator_mode)::text = ANY (ARRAY[('external_calculation'::character varying)::text, ('provider_calculation'::character varying)::text])))),
    CONSTRAINT rs_billing_commands_complete_claim CHECK ((((claim_token IS NULL) AND (claimed_at IS NULL) AND (lease_expires_at IS NULL)) OR ((claim_token IS NOT NULL) AND (claimed_at IS NOT NULL) AND (lease_expires_at > claimed_at)))),
    CONSTRAINT rs_billing_commands_error_object CHECK ((jsonb_typeof(safe_error_details) = 'object'::text)),
    CONSTRAINT rs_billing_commands_fingerprint CHECK (((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_commands_one_executor CHECK ((((provider_account_recording_id IS NOT NULL) AND (provider_adapter_key IS NOT NULL) AND (calculator_key IS NULL) AND (calculator_mode IS NULL)) OR ((provider_account_recording_id IS NULL) AND (provider_adapter_key IS NULL) AND (calculator_key IS NOT NULL) AND (calculator_mode IS NOT NULL)))),
    CONSTRAINT rs_billing_commands_processing_claimed CHECK ((((state)::text = 'processing'::text) = (claim_token IS NOT NULL))),
    CONSTRAINT rs_billing_commands_provider_adapter_key CHECK (((provider_adapter_key IS NULL) OR ((provider_adapter_key)::text ~ '^[a-z][a-z0-9_]*$'::text))),
    CONSTRAINT rs_billing_commands_reconciliation_state CHECK (((reconciliation_state)::text = ANY (ARRAY[('not_required'::character varying)::text, ('pending'::character varying)::text, ('processing'::character varying)::text, ('reconciled'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT rs_billing_commands_request_object CHECK ((jsonb_typeof(canonical_request) = 'object'::text)),
    CONSTRAINT rs_billing_commands_result_object CHECK ((jsonb_typeof(normalized_result) = 'object'::text)),
    CONSTRAINT rs_billing_commands_state CHECK (((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('processing'::character varying)::text, ('succeeded'::character varying)::text, ('failed'::character varying)::text, ('uncertain'::character varying)::text, ('requires_reconciliation'::character varying)::text, ('cancelled'::character varying)::text]))),
    CONSTRAINT rs_billing_commands_type_format CHECK (((command_type)::text ~ '^[a-z][a-z0-9_]*$'::text))
);

-- Name: recording_studio_billing_invoice_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_invoice_lines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    invoice_id uuid NOT NULL,
    description character varying NOT NULL,
    currency_code character varying NOT NULL,
    amount_minor bigint NOT NULL,
    quantity integer NOT NULL,
    manifest_digest character varying,
    safe_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_invoice_line_amount CHECK (((amount_minor >= 0) AND (quantity > 0) AND ((currency_code)::text ~ '^[A-Z]{3}$'::text)))
);

-- Name: recording_studio_billing_invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    financial_command_id uuid,
    currency_code character varying NOT NULL,
    total_minor bigint NOT NULL,
    state character varying NOT NULL,
    issued_at timestamp(6) without time zone NOT NULL,
    safe_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    provider_reference character varying,
    subtotal_minor bigint,
    discount_minor bigint,
    tax_minor bigint,
    subscription_id uuid,
    purchase_id uuid,
    CONSTRAINT rs_billing_invoice_amount CHECK (((total_minor >= 0) AND ((currency_code)::text ~ '^[A-Z]{3}$'::text)))
);

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
    ppa_policy character varying DEFAULT 'standard'::character varying NOT NULL,
    rounding_policy character varying DEFAULT 'standard'::character varying NOT NULL,
    tax_presentation_policy character varying DEFAULT 'exclusive'::character varying NOT NULL,
    verification_policy character varying DEFAULT 'none'::character varying NOT NULL,
    country_groups jsonb DEFAULT '{}'::jsonb NOT NULL,
    default_currency_code character varying,
    regional_country_codes jsonb DEFAULT '[]'::jsonb NOT NULL,
    global_fallback boolean DEFAULT false NOT NULL,
    CONSTRAINT recording_studio_billing_markets_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_markets_global_fallback_scope CHECK (((NOT global_fallback) OR ((country_codes = '[]'::jsonb) AND (country_groups = '{}'::jsonb) AND (regional_country_codes = '[]'::jsonb)))),
    CONSTRAINT rs_billing_markets_priority CHECK ((priority >= 0)),
    CONSTRAINT rs_billing_markets_regional_country_codes CHECK (public.rs_billing_country_code_array_valid(regional_country_codes)),
    CONSTRAINT rs_billing_markets_specificity CHECK ((specificity >= 0))
);

-- Name: recording_studio_billing_meter_aggregations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_meter_aggregations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    meter_recording_id uuid NOT NULL,
    usage_unit_recording_id uuid NOT NULL,
    manifest_digest character varying NOT NULL,
    aggregation character varying NOT NULL,
    window_starts_at timestamp(6) without time zone NOT NULL,
    window_ends_at timestamp(6) without time zone NOT NULL,
    aggregated_at timestamp(6) without time zone NOT NULL,
    quantity bigint NOT NULL,
    event_count integer NOT NULL,
    usage_event_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    input_digest character varying NOT NULL,
    input_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_meter_aggregation_event_ids CHECK ((cardinality(usage_event_ids) = event_count)),
    CONSTRAINT rs_billing_meter_aggregation_events CHECK ((event_count > 0)),
    CONSTRAINT rs_billing_meter_aggregation_input_object CHECK ((jsonb_typeof(input_snapshot) = 'object'::text)),
    CONSTRAINT rs_billing_meter_aggregation_metadata_object CHECK ((jsonb_typeof(safe_metadata) = 'object'::text)),
    CONSTRAINT rs_billing_meter_aggregation_mode CHECK (((aggregation)::text = ANY (ARRAY[('sum'::character varying)::text, ('count'::character varying)::text, ('maximum'::character varying)::text, ('latest'::character varying)::text]))),
    CONSTRAINT rs_billing_meter_aggregation_window CHECK ((window_ends_at > window_starts_at))
);

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
    CONSTRAINT recording_studio_billing_meters_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_meters_aggregation CHECK (((aggregation)::text = ANY (ARRAY[('sum'::character varying)::text, ('count'::character varying)::text, ('maximum'::character varying)::text, ('latest'::character varying)::text])))
);

-- Name: recording_studio_billing_overage_calculations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_overage_calculations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    usage_allocation_id uuid NOT NULL,
    excess_quantity bigint NOT NULL,
    amount_minor bigint NOT NULL,
    currency_code character varying NOT NULL,
    currency_exponent integer NOT NULL,
    rate_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    overage_price_recording_id uuid,
    CONSTRAINT rs_billing_overage_calculation_amount CHECK (((excess_quantity >= 0) AND (amount_minor >= 0)))
);

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
    scope character varying DEFAULT 'market'::character varying NOT NULL,
    review_threshold_minor bigint,
    hard_threshold_minor bigint,
    maximum_period_liability_minor bigint,
    maximum_submission_minor bigint,
    CONSTRAINT recording_studio_billing_overage_prices_amount_minor CHECK ((amount_minor >= 0)),
    CONSTRAINT recording_studio_billing_overage_prices_currency_code CHECK (((currency_code)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT recording_studio_billing_overage_prices_currency_exponent CHECK (((currency_exponent >= 0) AND (currency_exponent <= 3))),
    CONSTRAINT recording_studio_billing_overage_prices_package_size CHECK (((((pricing_model)::text = 'package'::text) AND (package_size IS NOT NULL) AND (package_size > 0)) OR (((pricing_model)::text = ANY (ARRAY[('flat'::character varying)::text, ('per_unit'::character varying)::text])) AND (package_size IS NULL)))),
    CONSTRAINT recording_studio_billing_overage_prices_pricing_model CHECK (((pricing_model)::text = ANY (ARRAY[('flat'::character varying)::text, ('per_unit'::character varying)::text, ('package'::character varying)::text]))),
    CONSTRAINT recording_studio_billing_overage_prices_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT recording_studio_billing_overage_prices_v1_scope CHECK (((scope)::text = 'market'::text)),
    CONSTRAINT recording_studio_billing_overage_prices_version CHECK ((version >= 1)),
    CONSTRAINT rs_billing_overage_hard_threshold CHECK (((hard_threshold_minor IS NULL) OR (hard_threshold_minor >= 0))),
    CONSTRAINT rs_billing_overage_period_liability_limit CHECK (((maximum_period_liability_minor IS NULL) OR (maximum_period_liability_minor >= 0))),
    CONSTRAINT rs_billing_overage_review_threshold CHECK (((review_threshold_minor IS NULL) OR (review_threshold_minor >= 0))),
    CONSTRAINT rs_billing_overage_submission_limit CHECK (((maximum_submission_minor IS NULL) OR (maximum_submission_minor >= 0)))
);

-- Name: recording_studio_billing_payment_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_payment_allocations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    payment_id uuid NOT NULL,
    invoice_id uuid,
    amount_minor bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_payment_allocation_amount CHECK ((amount_minor > 0))
);

-- Name: recording_studio_billing_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    financial_command_id uuid NOT NULL,
    provider_reference character varying,
    currency_code character varying NOT NULL,
    amount_minor bigint NOT NULL,
    state character varying NOT NULL,
    safe_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    recorded_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    subtotal_minor bigint,
    discount_minor bigint,
    tax_minor bigint,
    invoice_id uuid,
    CONSTRAINT rs_billing_payment_amount CHECK (((amount_minor >= 0) AND ((currency_code)::text ~ '^[A-Z]{3}$'::text)))
);

-- Name: recording_studio_billing_plan_update_applications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_plan_update_applications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_update_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    subscription_change_intent_id uuid NOT NULL,
    state character varying DEFAULT 'pending'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    plan_update_run_id uuid NOT NULL
);

-- Name: recording_studio_billing_plan_update_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_plan_update_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_update_id uuid NOT NULL,
    idempotency_key character varying NOT NULL,
    request_fingerprint character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    scheduled_at timestamp(6) without time zone,
    preview jsonb DEFAULT '{}'::jsonb NOT NULL,
    confirmation jsonb DEFAULT '{}'::jsonb NOT NULL,
    reconciliation jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_plan_update_run_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('previewed'::character varying)::text, ('awaiting_confirmation'::character varying)::text, ('scheduled'::character varying)::text, ('applying'::character varying)::text, ('applied'::character varying)::text, ('failed'::character varying)::text, ('requires_review'::character varying)::text])))
);

-- Name: recording_studio_billing_plan_updates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_plan_updates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    billing_option_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    preview jsonb DEFAULT '{}'::jsonb NOT NULL,
    confirmation jsonb DEFAULT '{}'::jsonb NOT NULL,
    effective_at timestamp(6) without time zone,
    audience jsonb DEFAULT '{}'::jsonb NOT NULL,
    allowance_policy character varying DEFAULT 'preserve'::character varying NOT NULL,
    execution_state character varying DEFAULT 'draft'::character varying NOT NULL,
    idempotency_key character varying,
    reconciliation_state character varying DEFAULT 'not_required'::character varying NOT NULL,
    replacement_manifest_digest character varying,
    replacement_configuration jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT recording_studio_billing_plan_updates_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_plan_update_allowance_policy CHECK (((allowance_policy)::text = ANY (ARRAY[('preserve'::character varying)::text, ('replace'::character varying)::text, ('reconcile'::character varying)::text]))),
    CONSTRAINT rs_billing_plan_update_execution_state CHECK (((execution_state)::text = ANY (ARRAY[('draft'::character varying)::text, ('previewed'::character varying)::text, ('confirmed'::character varying)::text, ('scheduled'::character varying)::text, ('applying'::character varying)::text, ('completed'::character varying)::text, ('requires_review'::character varying)::text, ('failed'::character varying)::text])))
);

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
    scope character varying DEFAULT 'market'::character varying NOT NULL,
    feature_values jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT recording_studio_billing_prices_amount_minor CHECK ((amount_minor >= 0)),
    CONSTRAINT recording_studio_billing_prices_currency_code CHECK (((currency_code)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT recording_studio_billing_prices_currency_exponent CHECK (((currency_exponent >= 0) AND (currency_exponent <= 3))),
    CONSTRAINT recording_studio_billing_prices_package_size CHECK (((((pricing_model)::text = 'package'::text) AND (package_size IS NOT NULL) AND (package_size > 0)) OR (((pricing_model)::text = ANY (ARRAY[('flat'::character varying)::text, ('per_unit'::character varying)::text])) AND (package_size IS NULL)))),
    CONSTRAINT recording_studio_billing_prices_pricing_model CHECK (((pricing_model)::text = ANY (ARRAY[('flat'::character varying)::text, ('per_unit'::character varying)::text, ('package'::character varying)::text]))),
    CONSTRAINT recording_studio_billing_prices_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT recording_studio_billing_prices_v1_scope CHECK (((scope)::text = 'market'::text)),
    CONSTRAINT recording_studio_billing_prices_version CHECK ((version >= 1))
);

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
    target_product_recording_id uuid NOT NULL,
    conditions jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT recording_studio_billing_product_rules_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
);

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
    CONSTRAINT recording_studio_billing_products_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_products_kind CHECK (((kind)::text = ANY (ARRAY[('plan'::character varying)::text, ('addon'::character varying)::text, ('credit_pack'::character varying)::text, ('service'::character varying)::text])))
);

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
    CONSTRAINT recording_studio_billing_provider_accounts_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_provider_accounts_provider_format CHECK (((adapter_key)::text ~ '^[a-z][a-z0-9_]*$'::text))
);

-- Name: recording_studio_billing_provider_references; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_provider_references (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    financial_command_id uuid NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    provider_adapter_key character varying NOT NULL,
    environment character varying NOT NULL,
    reference character varying NOT NULL,
    reference_type character varying DEFAULT 'operation'::character varying NOT NULL,
    remote_type character varying NOT NULL,
    remote_id character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_provider_reference_safe_remote_identity CHECK ((((remote_type)::text ~ '^[a-zA-Z0-9_.:-]+$'::text) AND ((remote_id)::text ~ '^[a-zA-Z0-9_.:-]+$'::text)))
);

-- Name: recording_studio_billing_purchase_effects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_purchase_effects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    purchase_id uuid NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    effect_kind character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    manifest_digest character varying NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    effective_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_purchase_effect_digest CHECK (((manifest_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_purchase_effect_kind CHECK (((effect_kind)::text = ANY (ARRAY[('one_off_addon'::character varying)::text, ('credit_pack'::character varying)::text]))),
    CONSTRAINT rs_billing_purchase_effect_metadata_object CHECK ((jsonb_typeof(safe_metadata) = 'object'::text))
);

-- Name: recording_studio_billing_purchases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_purchases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    checkout_intent_id uuid NOT NULL,
    checkout_intent_item_id uuid NOT NULL,
    product_recording_id uuid NOT NULL,
    billing_option_recording_id uuid NOT NULL,
    price_recording_id uuid NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    provider_adapter_key character varying NOT NULL,
    mode character varying NOT NULL,
    currency_code character varying NOT NULL,
    amount_minor bigint NOT NULL,
    quantity integer NOT NULL,
    manifest_digest character varying NOT NULL,
    commercial_snapshot jsonb NOT NULL,
    completed_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_purchase_amount_quantity CHECK (((amount_minor >= 0) AND (quantity > 0))),
    CONSTRAINT rs_billing_purchase_currency CHECK (((currency_code)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT rs_billing_purchase_digest CHECK (((manifest_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_purchase_modes CHECK (((mode)::text = ANY (ARRAY[('one_off_addon'::character varying)::text, ('one_off_credit_pack'::character varying)::text]))),
    CONSTRAINT rs_billing_purchase_snapshot_object CHECK ((jsonb_typeof(commercial_snapshot) = 'object'::text))
);

-- Name: recording_studio_billing_rate_cards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_rate_cards (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_studio_billing_rate_cards_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
);

-- Name: recording_studio_billing_rated_usage_settlements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_rated_usage_settlements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    rated_usage_id uuid,
    financial_command_id uuid NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    manifest_digest character varying NOT NULL,
    canonical_request jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_fingerprint character varying NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    usage_period_id uuid,
    CONSTRAINT rs_billing_settlement_fingerprint CHECK (((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_settlement_manifest_digest CHECK (((manifest_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_settlement_metadata_object CHECK ((jsonb_typeof(safe_metadata) = 'object'::text)),
    CONSTRAINT rs_billing_settlement_request_object CHECK ((jsonb_typeof(canonical_request) = 'object'::text))
);

-- Name: recording_studio_billing_rated_usages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_rated_usages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    meter_aggregation_id uuid NOT NULL,
    manifest_digest character varying NOT NULL,
    rate_recording_id uuid NOT NULL,
    customer_price_recording_id uuid NOT NULL,
    cost_rate_recording_id uuid,
    rate_card_recording_id uuid NOT NULL,
    cost_card_recording_id uuid,
    quantity bigint NOT NULL,
    customer_amount_minor bigint,
    customer_currency_code character varying,
    customer_currency_exponent integer,
    cost_amount_minor bigint,
    cost_currency_code character varying,
    cost_currency_exponent integer,
    window_starts_at timestamp(6) without time zone NOT NULL,
    window_ends_at timestamp(6) without time zone NOT NULL,
    rated_at timestamp(6) without time zone NOT NULL,
    aggregation_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    rate_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_rated_usage_aggregation_object CHECK ((jsonb_typeof(aggregation_snapshot) = 'object'::text)),
    CONSTRAINT rs_billing_rated_usage_cost_money CHECK ((((cost_amount_minor IS NULL) AND (cost_currency_code IS NULL) AND (cost_currency_exponent IS NULL)) OR ((cost_amount_minor >= 0) AND ((cost_currency_code)::text ~ '^[A-Z]{3}$'::text) AND ((cost_currency_exponent >= 0) AND (cost_currency_exponent <= 3))))),
    CONSTRAINT rs_billing_rated_usage_customer_money CHECK ((((customer_amount_minor IS NULL) AND (customer_currency_code IS NULL) AND (customer_currency_exponent IS NULL)) OR ((customer_amount_minor >= 0) AND ((customer_currency_code)::text ~ '^[A-Z]{3}$'::text) AND ((customer_currency_exponent >= 0) AND (customer_currency_exponent <= 3))))),
    CONSTRAINT rs_billing_rated_usage_metadata_object CHECK ((jsonb_typeof(safe_metadata) = 'object'::text)),
    CONSTRAINT rs_billing_rated_usage_quantity CHECK ((quantity >= 0)),
    CONSTRAINT rs_billing_rated_usage_rate_object CHECK ((jsonb_typeof(rate_snapshot) = 'object'::text)),
    CONSTRAINT rs_billing_rated_usage_window CHECK ((window_ends_at > window_starts_at))
);

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
    CONSTRAINT recording_studio_billing_rates_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_rates_conversion CHECK ((((conversion_numerator IS NOT NULL) AND (conversion_numerator > 0) AND (conversion_denominator IS NOT NULL) AND (conversion_denominator > 0) AND (conversion_decimal IS NULL)) OR ((conversion_numerator IS NULL) AND (conversion_denominator IS NULL) AND (conversion_decimal IS NOT NULL) AND (conversion_decimal > (0)::numeric)))),
    CONSTRAINT rs_billing_rates_conversion_present CHECK ((NOT ((conversion_numerator IS NULL) AND (conversion_denominator IS NULL) AND (conversion_decimal IS NULL))))
);

-- Name: recording_studio_billing_reconciliation_issues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_reconciliation_issues (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    financial_command_id uuid,
    provider_account_recording_id uuid,
    authority character varying NOT NULL,
    kind character varying NOT NULL,
    state character varying DEFAULT 'open'::character varying NOT NULL,
    provider_adapter_key character varying,
    event_id character varying,
    environment character varying,
    inbound_event_id uuid,
    handler_name character varying,
    action_version character varying,
    safe_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_reconciliation_issue_state CHECK (((state)::text = ANY (ARRAY[('open'::character varying)::text, ('resolved'::character varying)::text, ('ignored'::character varying)::text])))
);

-- Name: recording_studio_billing_reconciliation_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_reconciliation_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    financial_command_id uuid NOT NULL,
    authority character varying NOT NULL,
    outcome character varying NOT NULL,
    safe_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

-- Name: recording_studio_billing_refund_intents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_refund_intents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    payment_id uuid NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    financial_command_id uuid,
    local_idempotency_key character varying NOT NULL,
    state character varying DEFAULT 'pending'::character varying NOT NULL,
    amount_minor bigint NOT NULL,
    currency_code character varying NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    provider_account_recording_id uuid,
    request_fingerprint character varying,
    reason character varying,
    actor_reference character varying,
    tax_treatment character varying DEFAULT 'provider_default'::character varying NOT NULL,
    reversal_policy character varying DEFAULT 'none'::character varying NOT NULL,
    line_allocation jsonb DEFAULT '{}'::jsonb NOT NULL
);

-- Name: recording_studio_billing_refunds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_refunds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    refund_intent_id uuid NOT NULL,
    payment_id uuid NOT NULL,
    financial_command_id uuid NOT NULL,
    amount_minor bigint NOT NULL,
    currency_code character varying NOT NULL,
    provider_reference character varying,
    recorded_at timestamp(6) without time zone NOT NULL,
    safe_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

-- Name: recording_studio_billing_subscription_change_intents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_subscription_change_intents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    financial_command_id uuid,
    local_idempotency_key character varying NOT NULL,
    request_fingerprint character varying NOT NULL,
    state character varying DEFAULT 'pending'::character varying NOT NULL,
    change_kind character varying NOT NULL,
    effective_at timestamp(6) without time zone,
    change_set jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    current_manifest_digest character varying,
    proposed_manifest_digest character varying,
    frozen_terms jsonb DEFAULT '{}'::jsonb NOT NULL,
    provider_decision jsonb DEFAULT '{}'::jsonb NOT NULL,
    outcome jsonb DEFAULT '{}'::jsonb NOT NULL,
    timing character varying DEFAULT 'immediate'::character varying NOT NULL,
    proration_policy character varying DEFAULT 'none'::character varying NOT NULL,
    CONSTRAINT rs_billing_subscription_change_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('validated'::character varying)::text, ('awaiting_confirmation'::character varying)::text, ('pending_provider'::character varying)::text, ('scheduled'::character varying)::text, ('applied'::character varying)::text, ('failed'::character varying)::text, ('requires_review'::character varying)::text, ('cancelled'::character varying)::text, ('expired'::character varying)::text]))),
    CONSTRAINT rs_billing_subscription_change_timing CHECK (((timing)::text = ANY (ARRAY[('immediate'::character varying)::text, ('next_period'::character varying)::text])))
);

-- Name: recording_studio_billing_subscription_item_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_subscription_item_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    checkout_intent_id uuid,
    checkout_intent_item_id uuid,
    line_key character varying NOT NULL,
    version_number integer NOT NULL,
    product_recording_id uuid NOT NULL,
    billing_option_recording_id uuid NOT NULL,
    price_recording_id uuid NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    provider_adapter_key character varying NOT NULL,
    mode character varying NOT NULL,
    currency_code character varying NOT NULL,
    amount_minor bigint NOT NULL,
    quantity integer NOT NULL,
    "interval" character varying,
    interval_count integer,
    manifest_digest character varying NOT NULL,
    commercial_snapshot jsonb NOT NULL,
    effective_starts_at timestamp(6) without time zone NOT NULL,
    effective_ends_at timestamp(6) without time zone,
    superseded_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    subscription_item_id uuid NOT NULL,
    source_type character varying DEFAULT 'checkout'::character varying NOT NULL,
    source_id uuid,
    source_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT rs_billing_subscription_item_amount_quantity CHECK (((amount_minor >= 0) AND (quantity > 0))),
    CONSTRAINT rs_billing_subscription_item_currency CHECK (((currency_code)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT rs_billing_subscription_item_dates CHECK (((effective_ends_at IS NULL) OR (effective_ends_at >= effective_starts_at))),
    CONSTRAINT rs_billing_subscription_item_digest CHECK (((manifest_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_subscription_item_line_key CHECK (((line_key)::text ~ '^[0-9a-f-]{36}(:[0-9a-f-]{36})?$'::text)),
    CONSTRAINT rs_billing_subscription_item_modes CHECK (((mode)::text = ANY (ARRAY[('free_plan'::character varying)::text, ('monthly_subscription'::character varying)::text, ('annual_subscription'::character varying)::text, ('trial_subscription'::character varying)::text, ('recurring_addon'::character varying)::text]))),
    CONSTRAINT rs_billing_subscription_item_snapshot_object CHECK ((jsonb_typeof(commercial_snapshot) = 'object'::text)),
    CONSTRAINT rs_billing_subscription_item_version_source CHECK (((((source_type)::text = 'checkout'::text) AND (checkout_intent_id IS NOT NULL) AND (checkout_intent_item_id IS NOT NULL) AND (source_id IS NOT NULL)) OR (((source_type)::text = 'subscription_change'::text) AND (source_id IS NOT NULL))))
);

-- Name: recording_studio_billing_subscription_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_subscription_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    line_key character varying NOT NULL,
    state character varying DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_subscription_item_state CHECK (((state)::text = ANY (ARRAY[('active'::character varying)::text, ('cancelled'::character varying)::text])))
);

-- Name: recording_studio_billing_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    identifier uuid DEFAULT gen_random_uuid() NOT NULL,
    state character varying NOT NULL,
    provider_reference character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    currency_code character varying NOT NULL,
    collection_method character varying NOT NULL,
    billing_anchor character varying DEFAULT 'checkout'::character varying NOT NULL,
    payment_terms_days integer DEFAULT 0 NOT NULL,
    market_recording_id uuid NOT NULL,
    execution_group_fingerprint character varying NOT NULL,
    CONSTRAINT rs_billing_subscription_execution_identity CHECK ((((currency_code)::text ~ '^[A-Z]{3}$'::text) AND ((collection_method)::text = ANY (ARRAY[('automatic'::character varying)::text, ('send_invoice'::character varying)::text])) AND ((execution_group_fingerprint)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT rs_billing_subscriptions_state CHECK (((state)::text = ANY (ARRAY[('trialing'::character varying)::text, ('active'::character varying)::text, ('past_due'::character varying)::text, ('paused'::character varying)::text, ('cancelled'::character varying)::text, ('expired'::character varying)::text])))
);

-- Name: recording_studio_billing_tax_calculations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_tax_calculations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    financial_command_id uuid NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    commercial_manifest_id uuid NOT NULL,
    supersedes_id uuid,
    revision_number integer DEFAULT 1 NOT NULL,
    calculator_key character varying NOT NULL,
    calculator_mode character varying NOT NULL,
    manifest_digest character varying NOT NULL,
    transaction_type character varying NOT NULL,
    operation_reference character varying NOT NULL,
    request_fingerprint character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    subtotal_minor bigint NOT NULL,
    discount_minor bigint NOT NULL,
    tax_minor bigint NOT NULL,
    total_minor bigint NOT NULL,
    currency character varying NOT NULL,
    behavior character varying NOT NULL,
    status character varying NOT NULL,
    breakdown jsonb DEFAULT '[]'::jsonb NOT NULL,
    calculator_reference character varying NOT NULL,
    calculated_at timestamp(6) without time zone NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    manifest_digests jsonb DEFAULT '[]'::jsonb NOT NULL,
    CONSTRAINT rs_billing_tax_arithmetic CHECK (((((behavior)::text = 'exclusive'::text) AND (total_minor = ((subtotal_minor - discount_minor) + tax_minor))) OR (((behavior)::text = ANY (ARRAY[('inclusive'::character varying)::text, ('provider_default'::character varying)::text])) AND (total_minor = (subtotal_minor - discount_minor)) AND (tax_minor <= total_minor)))),
    CONSTRAINT rs_billing_tax_behavior CHECK (((behavior)::text = ANY (ARRAY[('inclusive'::character varying)::text, ('exclusive'::character varying)::text, ('provider_default'::character varying)::text]))),
    CONSTRAINT rs_billing_tax_calculator_key CHECK (((calculator_key)::text ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT rs_billing_tax_calculator_mode CHECK (((calculator_mode)::text = ANY (ARRAY[('external_calculation'::character varying)::text, ('provider_calculation'::character varying)::text]))),
    CONSTRAINT rs_billing_tax_currency CHECK (((currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT rs_billing_tax_digests CHECK ((((manifest_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT rs_billing_tax_discount CHECK ((discount_minor <= subtotal_minor)),
    CONSTRAINT rs_billing_tax_manifest_set CHECK (public.rs_billing_sorted_manifest_set(manifest_digests, (manifest_digest)::text)),
    CONSTRAINT rs_billing_tax_nonnegative CHECK (((subtotal_minor >= 0) AND (discount_minor >= 0) AND (tax_minor >= 0) AND (total_minor >= 0))),
    CONSTRAINT rs_billing_tax_revision CHECK (((revision_number > 0) AND ((revision_number = 1) = (supersedes_id IS NULL)))),
    CONSTRAINT rs_billing_tax_safe_json CHECK (((jsonb_typeof(breakdown) = 'array'::text) AND (jsonb_typeof(safe_metadata) = 'object'::text))),
    CONSTRAINT rs_billing_tax_status CHECK (((status)::text = ANY (ARRAY[('success'::character varying)::text, ('duplicate'::character varying)::text, ('invalid'::character varying)::text, ('unauthorized'::character varying)::text, ('unsupported'::character varying)::text, ('unsupported_tax_calculation'::character varying)::text, ('unsupported_checkout_mode'::character varying)::text, ('unsupported_checkout_composition'::character varying)::text, ('unsupported_subscription_composition'::character varying)::text, ('unsupported_market'::character varying)::text, ('unsupported_currency'::character varying)::text, ('charge_market_verification_unavailable'::character varying)::text, ('conflict'::character varying)::text, ('provider_unavailable'::character varying)::text, ('provider_rejected'::character varying)::text, ('pending'::character varying)::text, ('stale'::character varying)::text, ('rate_missing'::character varying)::text, ('rate_ambiguous'::character varying)::text, ('requires_review'::character varying)::text, ('failed'::character varying)::text, ('unknown'::character varying)::text])))
);

-- Name: recording_studio_billing_usage_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_usage_allocations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    rated_usage_id uuid NOT NULL,
    credit_key character varying NOT NULL,
    measured_quantity bigint NOT NULL,
    credited_quantity bigint DEFAULT 0 NOT NULL,
    excess_quantity bigint NOT NULL,
    state character varying DEFAULT 'closed'::character varying NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    usage_period_id uuid,
    CONSTRAINT rs_billing_usage_allocation_quantities CHECK (((measured_quantity >= 0) AND (credited_quantity >= 0) AND (excess_quantity >= 0) AND ((credited_quantity + excess_quantity) = measured_quantity))),
    CONSTRAINT rs_billing_usage_allocation_state CHECK (((state)::text = ANY (ARRAY[('closing'::character varying)::text, ('closed'::character varying)::text, ('reversed'::character varying)::text])))
);

-- Name: recording_studio_billing_usage_allowance_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_usage_allowance_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    usage_period_id uuid NOT NULL,
    usage_key character varying NOT NULL,
    policy_kind character varying DEFAULT 'hard_cap'::character varying NOT NULL,
    limit_quantity bigint NOT NULL,
    consumed_quantity bigint DEFAULT 0 NOT NULL,
    effective_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_usage_allowance_policy_expiry CHECK (((expires_at IS NULL) OR (expires_at > effective_at))),
    CONSTRAINT rs_billing_usage_allowance_policy_quantities CHECK ((((policy_kind)::text = ANY (ARRAY[('hard_limit'::character varying)::text, ('prepaid_only'::character varying)::text, ('prepaid_then_block'::character varying)::text, ('prepaid_then_overage'::character varying)::text, ('automatic_overage'::character varying)::text, ('unlimited'::character varying)::text, ('addon_required'::character varying)::text])) AND (limit_quantity >= 0) AND (consumed_quantity >= 0) AND (consumed_quantity <= limit_quantity)))
);

-- Name: recording_studio_billing_usage_corrections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_usage_corrections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    usage_allocation_id uuid NOT NULL,
    supersedes_id uuid,
    tax_calculation_id uuid,
    correction_kind character varying NOT NULL,
    quantity_delta bigint NOT NULL,
    reason character varying NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    financial_command_id uuid,
    CONSTRAINT rs_billing_usage_correction_delta CHECK ((((correction_kind)::text = ANY (ARRAY[('credit'::character varying)::text, ('debit'::character varying)::text, ('void'::character varying)::text])) AND (quantity_delta <> 0)))
);

-- Name: recording_studio_billing_usage_credit_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_usage_credit_allocations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    usage_allocation_id uuid NOT NULL,
    usage_credit_grant_id uuid NOT NULL,
    quantity bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_usage_credit_allocation_quantity CHECK ((quantity > 0))
);

-- Name: recording_studio_billing_usage_credit_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_usage_credit_grants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    credit_key character varying NOT NULL,
    quantity bigint NOT NULL,
    remaining_quantity bigint NOT NULL,
    effective_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone,
    reversed_at timestamp(6) without time zone,
    source_key character varying NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    grant_kind character varying DEFAULT 'credit'::character varying NOT NULL,
    CONSTRAINT rs_billing_usage_credit_grant_expiry CHECK (((expires_at IS NULL) OR (expires_at > effective_at))),
    CONSTRAINT rs_billing_usage_credit_grant_quantities CHECK (((quantity > 0) AND (remaining_quantity >= 0) AND (remaining_quantity <= quantity))),
    CONSTRAINT rs_billing_usage_grant_kind CHECK (((grant_kind)::text = ANY (ARRAY[('allowance'::character varying)::text, ('credit'::character varying)::text])))
);

-- Name: recording_studio_billing_usage_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_usage_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    usage_key character varying NOT NULL,
    feature_key character varying,
    usage_unit_recording_id uuid,
    quantity bigint NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    idempotency_key character varying NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    classification character varying DEFAULT 'timely'::character varying NOT NULL,
    late_usage_period_id uuid,
    CONSTRAINT rs_billing_usage_event_classification CHECK (((classification)::text = ANY (ARRAY[('timely'::character varying)::text, ('late'::character varying)::text]))),
    CONSTRAINT rs_billing_usage_event_late_period CHECK (((((classification)::text = 'timely'::text) AND (late_usage_period_id IS NULL)) OR (((classification)::text = 'late'::text) AND (late_usage_period_id IS NOT NULL)))),
    CONSTRAINT rs_billing_usage_event_metadata_object CHECK ((jsonb_typeof(safe_metadata) = 'object'::text)),
    CONSTRAINT rs_billing_usage_event_quantity CHECK ((quantity > 0))
);

-- Name: recording_studio_billing_usage_ledger_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_usage_ledger_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    usage_period_id uuid NOT NULL,
    usage_allocation_id uuid,
    usage_credit_grant_id uuid,
    supersedes_id uuid,
    entry_kind character varying NOT NULL,
    quantity bigint NOT NULL,
    sequence integer NOT NULL,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_usage_ledger_entry_shape CHECK ((((entry_kind)::text = ANY (ARRAY[('grant'::character varying)::text, ('consume'::character varying)::text, ('expire'::character varying)::text, ('reverse'::character varying)::text, ('adjustment'::character varying)::text, ('overage'::character varying)::text])) AND (quantity >= 0) AND (sequence > 0)))
);

-- Name: recording_studio_billing_usage_periods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_usage_periods (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    usage_key character varying NOT NULL,
    starts_at timestamp(6) without time zone NOT NULL,
    ends_at timestamp(6) without time zone NOT NULL,
    state character varying DEFAULT 'open'::character varying NOT NULL,
    closed_at timestamp(6) without time zone,
    safe_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT rs_billing_usage_period_state CHECK (((state)::text = ANY (ARRAY[('open'::character varying)::text, ('closing'::character varying)::text, ('closed'::character varying)::text, ('submitted'::character varying)::text, ('invoiced'::character varying)::text, ('reconciled'::character varying)::text, ('requires_review'::character varying)::text]))),
    CONSTRAINT rs_billing_usage_period_window CHECK ((ends_at > starts_at))
);

-- Name: recording_studio_billing_usage_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_usage_units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    key character varying NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_studio_billing_usage_units_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
);

-- Name: recording_studio_billing_webhook_effects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_webhook_effects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_adapter_key character varying NOT NULL,
    event_id character varying NOT NULL,
    provider_account_recording_id uuid NOT NULL,
    provider_reference_id uuid,
    environment character varying NOT NULL,
    inbound_event_id uuid NOT NULL,
    handler_name character varying NOT NULL,
    action_version character varying NOT NULL,
    financial_command_id uuid,
    safe_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    processed_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

-- Name: recording_studio_billing_accounts recording_studio_billing_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_accounts
    ADD CONSTRAINT recording_studio_billing_accounts_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_adjustment_intents recording_studio_billing_adjustment_intents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_adjustment_intents
    ADD CONSTRAINT recording_studio_billing_adjustment_intents_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_billing_admins recording_studio_billing_billing_admins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_billing_admins
    ADD CONSTRAINT recording_studio_billing_billing_admins_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_billing_options recording_studio_billing_billing_options_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_billing_options
    ADD CONSTRAINT recording_studio_billing_billing_options_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_checkout_attempts recording_studio_billing_checkout_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_attempts
    ADD CONSTRAINT recording_studio_billing_checkout_attempts_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_checkout_intent_items recording_studio_billing_checkout_intent_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intent_items
    ADD CONSTRAINT recording_studio_billing_checkout_intent_items_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_checkout_intents recording_studio_billing_checkout_intents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intents
    ADD CONSTRAINT recording_studio_billing_checkout_intents_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_commercial_manifests recording_studio_billing_commercial_manifests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_commercial_manifests
    ADD CONSTRAINT recording_studio_billing_commercial_manifests_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_commercial_publication_candidates recording_studio_billing_commercial_publication_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_commercial_publication_candidates
    ADD CONSTRAINT recording_studio_billing_commercial_publication_candidates_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_cost_cards recording_studio_billing_cost_cards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_cards
    ADD CONSTRAINT recording_studio_billing_cost_cards_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_cost_rates recording_studio_billing_cost_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_rates
    ADD CONSTRAINT recording_studio_billing_cost_rates_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_credit_ledger_entries recording_studio_billing_credit_ledger_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_credit_ledger_entries
    ADD CONSTRAINT recording_studio_billing_credit_ledger_entries_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_entitlement_grants recording_studio_billing_entitlement_grants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_entitlement_grants
    ADD CONSTRAINT recording_studio_billing_entitlement_grants_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_feature_overrides recording_studio_billing_feature_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_feature_overrides
    ADD CONSTRAINT recording_studio_billing_feature_overrides_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_features recording_studio_billing_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_features
    ADD CONSTRAINT recording_studio_billing_features_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_financial_adjustments recording_studio_billing_financial_adjustments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_adjustments
    ADD CONSTRAINT recording_studio_billing_financial_adjustments_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_financial_command_attempts recording_studio_billing_financial_command_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_command_attempts
    ADD CONSTRAINT recording_studio_billing_financial_command_attempts_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_financial_commands recording_studio_billing_financial_commands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_commands
    ADD CONSTRAINT recording_studio_billing_financial_commands_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_invoice_lines recording_studio_billing_invoice_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_invoice_lines
    ADD CONSTRAINT recording_studio_billing_invoice_lines_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_invoices recording_studio_billing_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_invoices
    ADD CONSTRAINT recording_studio_billing_invoices_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_markets recording_studio_billing_markets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_markets
    ADD CONSTRAINT recording_studio_billing_markets_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_meter_aggregations recording_studio_billing_meter_aggregations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_meter_aggregations
    ADD CONSTRAINT recording_studio_billing_meter_aggregations_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_meters recording_studio_billing_meters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_meters
    ADD CONSTRAINT recording_studio_billing_meters_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_overage_calculations recording_studio_billing_overage_calculations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_calculations
    ADD CONSTRAINT recording_studio_billing_overage_calculations_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_overage_prices recording_studio_billing_overage_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_prices
    ADD CONSTRAINT recording_studio_billing_overage_prices_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_payment_allocations recording_studio_billing_payment_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_payment_allocations
    ADD CONSTRAINT recording_studio_billing_payment_allocations_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_payments recording_studio_billing_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_payments
    ADD CONSTRAINT recording_studio_billing_payments_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_plan_update_applications recording_studio_billing_plan_update_applications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_update_applications
    ADD CONSTRAINT recording_studio_billing_plan_update_applications_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_plan_update_runs recording_studio_billing_plan_update_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_update_runs
    ADD CONSTRAINT recording_studio_billing_plan_update_runs_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_plan_updates recording_studio_billing_plan_updates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_updates
    ADD CONSTRAINT recording_studio_billing_plan_updates_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_prices recording_studio_billing_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_prices
    ADD CONSTRAINT recording_studio_billing_prices_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_product_rules recording_studio_billing_product_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_product_rules
    ADD CONSTRAINT recording_studio_billing_product_rules_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_products recording_studio_billing_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_products
    ADD CONSTRAINT recording_studio_billing_products_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_provider_accounts recording_studio_billing_provider_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_provider_accounts
    ADD CONSTRAINT recording_studio_billing_provider_accounts_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_provider_references recording_studio_billing_provider_references_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_provider_references
    ADD CONSTRAINT recording_studio_billing_provider_references_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_purchase_effects recording_studio_billing_purchase_effects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchase_effects
    ADD CONSTRAINT recording_studio_billing_purchase_effects_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_purchases recording_studio_billing_purchases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchases
    ADD CONSTRAINT recording_studio_billing_purchases_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_rate_cards recording_studio_billing_rate_cards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rate_cards
    ADD CONSTRAINT recording_studio_billing_rate_cards_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_rated_usage_settlements recording_studio_billing_rated_usage_settlements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usage_settlements
    ADD CONSTRAINT recording_studio_billing_rated_usage_settlements_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_rated_usages recording_studio_billing_rated_usages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usages
    ADD CONSTRAINT recording_studio_billing_rated_usages_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_rates recording_studio_billing_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rates
    ADD CONSTRAINT recording_studio_billing_rates_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_reconciliation_issues recording_studio_billing_reconciliation_issues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_reconciliation_issues
    ADD CONSTRAINT recording_studio_billing_reconciliation_issues_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_reconciliation_records recording_studio_billing_reconciliation_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_reconciliation_records
    ADD CONSTRAINT recording_studio_billing_reconciliation_records_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_refund_intents recording_studio_billing_refund_intents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_refund_intents
    ADD CONSTRAINT recording_studio_billing_refund_intents_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_refunds recording_studio_billing_refunds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_refunds
    ADD CONSTRAINT recording_studio_billing_refunds_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_subscription_change_intents recording_studio_billing_subscription_change_intents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_change_intents
    ADD CONSTRAINT recording_studio_billing_subscription_change_intents_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_subscription_item_versions recording_studio_billing_subscription_item_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT recording_studio_billing_subscription_item_versions_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_subscription_items recording_studio_billing_subscription_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_items
    ADD CONSTRAINT recording_studio_billing_subscription_items_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_subscriptions recording_studio_billing_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscriptions
    ADD CONSTRAINT recording_studio_billing_subscriptions_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_tax_calculations recording_studio_billing_tax_calculations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT recording_studio_billing_tax_calculations_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_usage_allocations recording_studio_billing_usage_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_allocations
    ADD CONSTRAINT recording_studio_billing_usage_allocations_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_usage_allowance_policies recording_studio_billing_usage_allowance_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_allowance_policies
    ADD CONSTRAINT recording_studio_billing_usage_allowance_policies_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_usage_corrections recording_studio_billing_usage_corrections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_corrections
    ADD CONSTRAINT recording_studio_billing_usage_corrections_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_usage_credit_allocations recording_studio_billing_usage_credit_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_credit_allocations
    ADD CONSTRAINT recording_studio_billing_usage_credit_allocations_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_usage_credit_grants recording_studio_billing_usage_credit_grants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_credit_grants
    ADD CONSTRAINT recording_studio_billing_usage_credit_grants_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_usage_events recording_studio_billing_usage_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_events
    ADD CONSTRAINT recording_studio_billing_usage_events_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_usage_ledger_entries recording_studio_billing_usage_ledger_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_ledger_entries
    ADD CONSTRAINT recording_studio_billing_usage_ledger_entries_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_usage_periods recording_studio_billing_usage_periods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_periods
    ADD CONSTRAINT recording_studio_billing_usage_periods_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_usage_units recording_studio_billing_usage_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_units
    ADD CONSTRAINT recording_studio_billing_usage_units_pkey PRIMARY KEY (id);

-- Name: recording_studio_billing_webhook_effects recording_studio_billing_webhook_effects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_webhook_effects
    ADD CONSTRAINT recording_studio_billing_webhook_effects_pkey PRIMARY KEY (id);

-- Name: idx_on_account_recording_id_10ff0769e5; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_10ff0769e5 ON public.recording_studio_billing_usage_allowance_policies USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_1aba6ba035; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_1aba6ba035 ON public.recording_studio_billing_adjustment_intents USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_2171ed6580; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_2171ed6580 ON public.recording_studio_billing_credit_ledger_entries USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_3932840ef5; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_3932840ef5 ON public.recording_studio_billing_subscription_items USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_3fadc96c0d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_3fadc96c0d ON public.recording_studio_billing_rated_usages USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_40b0a22061; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_40b0a22061 ON public.recording_studio_billing_subscription_item_versions USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_513c128e1f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_513c128e1f ON public.recording_studio_billing_subscriptions USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_52268c115a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_52268c115a ON public.recording_studio_billing_subscription_change_intents USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_530b2ad4ba; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_530b2ad4ba ON public.recording_studio_billing_purchases USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_60eab6e700; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_60eab6e700 ON public.recording_studio_billing_purchase_effects USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_65f04aad25; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_65f04aad25 ON public.recording_studio_billing_usage_ledger_entries USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_6958c7ae61; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_6958c7ae61 ON public.recording_studio_billing_usage_periods USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_6fabd12b88; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_6fabd12b88 ON public.recording_studio_billing_usage_credit_grants USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_734f203c5c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_734f203c5c ON public.recording_studio_billing_usage_allocations USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_78c80a89c5; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_78c80a89c5 ON public.recording_studio_billing_usage_events USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_8e401e15ba; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_8e401e15ba ON public.recording_studio_billing_checkout_intents USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_937d9dc223; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_937d9dc223 ON public.recording_studio_billing_financial_commands USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_9da7a86b69; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_9da7a86b69 ON public.recording_studio_billing_refund_intents USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_9e348b517e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_9e348b517e ON public.recording_studio_billing_entitlement_grants USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_b17008f7e2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_b17008f7e2 ON public.recording_studio_billing_rated_usage_settlements USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_bf46d23ae6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_bf46d23ae6 ON public.recording_studio_billing_feature_overrides USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_cb3ff602b6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_cb3ff602b6 ON public.recording_studio_billing_meter_aggregations USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_cd6cb724a1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_cd6cb724a1 ON public.recording_studio_billing_tax_calculations USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_d4af546da8; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_d4af546da8 ON public.recording_studio_billing_invoices USING btree (account_recording_id);

-- Name: idx_on_account_recording_id_df8c8b4dfc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_df8c8b4dfc ON public.recording_studio_billing_payments USING btree (account_recording_id);

-- Name: idx_on_adjustment_intent_id_1b4251eb93; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_adjustment_intent_id_1b4251eb93 ON public.recording_studio_billing_financial_adjustments USING btree (adjustment_intent_id);

-- Name: idx_on_billing_admin_recording_id_e9c004ac4f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_billing_admin_recording_id_e9c004ac4f ON public.recording_studio_billing_provider_accounts USING btree (billing_admin_recording_id);

-- Name: idx_on_billing_option_recording_id_4b4b3a8dfa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_billing_option_recording_id_4b4b3a8dfa ON public.recording_studio_billing_overage_prices USING btree (billing_option_recording_id);

-- Name: idx_on_billing_option_recording_id_df8562f2e7; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_billing_option_recording_id_df8562f2e7 ON public.recording_studio_billing_plan_updates USING btree (billing_option_recording_id);

-- Name: idx_on_billing_option_recording_id_f4dd8ca6e3; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_billing_option_recording_id_f4dd8ca6e3 ON public.recording_studio_billing_prices USING btree (billing_option_recording_id);

-- Name: idx_on_checkout_intent_id_3bbe25d7ff; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_checkout_intent_id_3bbe25d7ff ON public.recording_studio_billing_checkout_intent_items USING btree (checkout_intent_id);

-- Name: idx_on_checkout_intent_id_3c0ba4cf49; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_checkout_intent_id_3c0ba4cf49 ON public.recording_studio_billing_checkout_attempts USING btree (checkout_intent_id);

-- Name: idx_on_checkout_intent_id_60a7fdca1d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_checkout_intent_id_60a7fdca1d ON public.recording_studio_billing_subscription_item_versions USING btree (checkout_intent_id);

-- Name: idx_on_commercial_manifest_id_c6e0df96a7; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_commercial_manifest_id_c6e0df96a7 ON public.recording_studio_billing_tax_calculations USING btree (commercial_manifest_id);

-- Name: idx_on_cost_card_recording_id_f59059cf73; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_cost_card_recording_id_f59059cf73 ON public.recording_studio_billing_cost_rates USING btree (cost_card_recording_id);

-- Name: idx_on_effective_at_7e599d09df; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_effective_at_7e599d09df ON public.recording_studio_billing_commercial_publication_candidates USING btree (effective_at);

-- Name: idx_on_feature_recording_id_6dcf40615b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_feature_recording_id_6dcf40615b ON public.recording_studio_billing_feature_overrides USING btree (feature_recording_id);

-- Name: idx_on_financial_command_attempt_id_0ab43bb24a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_attempt_id_0ab43bb24a ON public.recording_studio_billing_checkout_attempts USING btree (financial_command_attempt_id);

-- Name: idx_on_financial_command_id_0ee66789ae; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_0ee66789ae ON public.recording_studio_billing_rated_usage_settlements USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_144b6e8c5b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_144b6e8c5b ON public.recording_studio_billing_checkout_intents USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_17822cb411; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_17822cb411 ON public.recording_studio_billing_reconciliation_issues USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_2a8556545f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_2a8556545f ON public.recording_studio_billing_reconciliation_records USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_3a27e3d203; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_3a27e3d203 ON public.recording_studio_billing_financial_adjustments USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_48ec1b5e2a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_48ec1b5e2a ON public.recording_studio_billing_invoices USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_6b7f641e35; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_6b7f641e35 ON public.recording_studio_billing_checkout_attempts USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_714c40ec67; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_714c40ec67 ON public.recording_studio_billing_usage_corrections USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_7960b6548f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_7960b6548f ON public.recording_studio_billing_provider_references USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_805027e9f2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_805027e9f2 ON public.recording_studio_billing_webhook_effects USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_81fdfb0193; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_81fdfb0193 ON public.recording_studio_billing_financial_command_attempts USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_97f8b55c4d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_97f8b55c4d ON public.recording_studio_billing_refund_intents USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_ae8a6bd007; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_ae8a6bd007 ON public.recording_studio_billing_subscription_change_intents USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_c5e92b5d40; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_c5e92b5d40 ON public.recording_studio_billing_adjustment_intents USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_df93af6f81; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_df93af6f81 ON public.recording_studio_billing_tax_calculations USING btree (financial_command_id);

-- Name: idx_on_financial_command_id_efe8bfb786; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_efe8bfb786 ON public.recording_studio_billing_payments USING btree (financial_command_id);

-- Name: idx_on_invoice_id_080d3004ae; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_invoice_id_080d3004ae ON public.recording_studio_billing_payment_allocations USING btree (invoice_id);

-- Name: idx_on_invoice_id_e4d1a9c280; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_invoice_id_e4d1a9c280 ON public.recording_studio_billing_financial_adjustments USING btree (invoice_id);

-- Name: idx_on_invoice_id_edc1e8c055; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_invoice_id_edc1e8c055 ON public.recording_studio_billing_adjustment_intents USING btree (invoice_id);

-- Name: idx_on_late_usage_period_id_d90d84058e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_late_usage_period_id_d90d84058e ON public.recording_studio_billing_usage_events USING btree (late_usage_period_id);

-- Name: idx_on_manifest_digest_b5d415588d; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_manifest_digest_b5d415588d ON public.recording_studio_billing_commercial_manifests USING btree (manifest_digest);

-- Name: idx_on_market_recording_id_2ba99ee38f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_market_recording_id_2ba99ee38f ON public.recording_studio_billing_overage_prices USING btree (market_recording_id);

-- Name: idx_on_meter_aggregation_id_e92f2d7213; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_meter_aggregation_id_e92f2d7213 ON public.recording_studio_billing_rated_usages USING btree (meter_aggregation_id);

-- Name: idx_on_overage_price_recording_id_2ef7fea3a9; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_overage_price_recording_id_2ef7fea3a9 ON public.recording_studio_billing_overage_calculations USING btree (overage_price_recording_id);

-- Name: idx_on_payment_id_08ef28acb2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_payment_id_08ef28acb2 ON public.recording_studio_billing_payment_allocations USING btree (payment_id);

-- Name: idx_on_plan_update_id_6ed2afbda9; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_plan_update_id_6ed2afbda9 ON public.recording_studio_billing_plan_update_runs USING btree (plan_update_id);

-- Name: idx_on_plan_update_id_9936e2a156; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_plan_update_id_9936e2a156 ON public.recording_studio_billing_plan_update_applications USING btree (plan_update_id);

-- Name: idx_on_plan_update_run_id_b15568ea7c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_plan_update_run_id_b15568ea7c ON public.recording_studio_billing_plan_update_applications USING btree (plan_update_run_id);

-- Name: idx_on_product_recording_id_387e136700; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_product_recording_id_387e136700 ON public.recording_studio_billing_billing_options USING btree (product_recording_id);

-- Name: idx_on_product_recording_id_b3abe2c34c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_product_recording_id_b3abe2c34c ON public.recording_studio_billing_features USING btree (product_recording_id);

-- Name: idx_on_product_recording_id_cca2c7df22; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_product_recording_id_cca2c7df22 ON public.recording_studio_billing_product_rules USING btree (product_recording_id);

-- Name: idx_on_provider_account_recording_id_50c2346f3a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_50c2346f3a ON public.recording_studio_billing_reconciliation_issues USING btree (provider_account_recording_id);

-- Name: idx_on_provider_account_recording_id_56b2cacbb5; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_56b2cacbb5 ON public.recording_studio_billing_provider_references USING btree (provider_account_recording_id);

-- Name: idx_on_provider_account_recording_id_75eb593078; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_75eb593078 ON public.recording_studio_billing_products USING btree (provider_account_recording_id);

-- Name: idx_on_provider_account_recording_id_829622d336; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_829622d336 ON public.recording_studio_billing_rate_cards USING btree (provider_account_recording_id);

-- Name: idx_on_provider_account_recording_id_917bf5f52e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_917bf5f52e ON public.recording_studio_billing_markets USING btree (provider_account_recording_id);

-- Name: idx_on_provider_account_recording_id_9cd826d9a7; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_9cd826d9a7 ON public.recording_studio_billing_rated_usage_settlements USING btree (provider_account_recording_id);

-- Name: idx_on_provider_account_recording_id_b9ff1578aa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_b9ff1578aa ON public.recording_studio_billing_webhook_effects USING btree (provider_account_recording_id);

-- Name: idx_on_provider_account_recording_id_d0aeb02284; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_d0aeb02284 ON public.recording_studio_billing_usage_units USING btree (provider_account_recording_id);

-- Name: idx_on_provider_account_recording_id_de683655d9; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_de683655d9 ON public.recording_studio_billing_cost_cards USING btree (provider_account_recording_id);

-- Name: idx_on_provider_account_recording_id_e7e6d6a62d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_e7e6d6a62d ON public.recording_studio_billing_financial_commands USING btree (provider_account_recording_id);

-- Name: idx_on_provider_reference_id_877223171a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_reference_id_877223171a ON public.recording_studio_billing_webhook_effects USING btree (provider_reference_id);

-- Name: idx_on_purchase_effect_id_1cf8fc1656; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_purchase_effect_id_1cf8fc1656 ON public.recording_studio_billing_credit_ledger_entries USING btree (purchase_effect_id);

-- Name: idx_on_rated_usage_id_7de35e3caa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_rated_usage_id_7de35e3caa ON public.recording_studio_billing_usage_allocations USING btree (rated_usage_id);

-- Name: idx_on_rated_usage_id_93c519e44f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_rated_usage_id_93c519e44f ON public.recording_studio_billing_rated_usage_settlements USING btree (rated_usage_id);

-- Name: idx_on_root_recording_id_107421795e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_107421795e ON public.recording_studio_billing_subscription_item_versions USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_12ea494079; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_12ea494079 ON public.recording_studio_billing_usage_credit_grants USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_162489a73e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_162489a73e ON public.recording_studio_billing_meter_aggregations USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_251c7974b6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_251c7974b6 ON public.recording_studio_billing_usage_ledger_entries USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_3e16fc4553; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_3e16fc4553 ON public.recording_studio_billing_rated_usage_settlements USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_52395a8cdb; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_52395a8cdb ON public.recording_studio_billing_subscriptions USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_5ca6fd8892; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_5ca6fd8892 ON public.recording_studio_billing_subscription_change_intents USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_60cb5f5f5f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_60cb5f5f5f ON public.recording_studio_billing_refund_intents USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_7a0cf6614f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_7a0cf6614f ON public.recording_studio_billing_subscription_items USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_88b3d7e1ce; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_88b3d7e1ce ON public.recording_studio_billing_usage_allowance_policies USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_90af0f36c2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_90af0f36c2 ON public.recording_studio_billing_usage_events USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_9d3d42ce71; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_9d3d42ce71 ON public.recording_studio_billing_credit_ledger_entries USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_9fc1094773; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_9fc1094773 ON public.recording_studio_billing_rated_usages USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_c1ebf50973; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_c1ebf50973 ON public.recording_studio_billing_financial_commands USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_c9449b0ded; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_c9449b0ded ON public.recording_studio_billing_tax_calculations USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_cdf921461c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_cdf921461c ON public.recording_studio_billing_usage_allocations USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_d0e6016597; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_d0e6016597 ON public.recording_studio_billing_usage_periods USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_d63849b28a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_d63849b28a ON public.recording_studio_billing_commercial_manifests USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_d9bf1cf3de; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_d9bf1cf3de ON public.recording_studio_billing_entitlement_grants USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_e8f7404b06; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_e8f7404b06 ON public.recording_studio_billing_purchase_effects USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_f2e0c629cd; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_f2e0c629cd ON public.recording_studio_billing_adjustment_intents USING btree (root_recording_id);

-- Name: idx_on_root_recording_id_f7b40e9183; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_f7b40e9183 ON public.recording_studio_billing_checkout_intents USING btree (root_recording_id);

-- Name: idx_on_subscription_change_intent_id_31703813d4; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_subscription_change_intent_id_31703813d4 ON public.recording_studio_billing_plan_update_applications USING btree (subscription_change_intent_id);

-- Name: idx_on_subscription_id_0945def460; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_subscription_id_0945def460 ON public.recording_studio_billing_plan_update_applications USING btree (subscription_id);

-- Name: idx_on_subscription_id_8316ef20d6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_subscription_id_8316ef20d6 ON public.recording_studio_billing_subscription_change_intents USING btree (subscription_id);

-- Name: idx_on_subscription_id_bcde3897cb; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_subscription_id_bcde3897cb ON public.recording_studio_billing_subscription_items USING btree (subscription_id);

-- Name: idx_on_subscription_id_eca2627d32; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_subscription_id_eca2627d32 ON public.recording_studio_billing_subscription_item_versions USING btree (subscription_id);

-- Name: idx_on_subscription_item_id_4e7863dc93; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_subscription_item_id_4e7863dc93 ON public.recording_studio_billing_subscription_item_versions USING btree (subscription_item_id);

-- Name: idx_on_supersedes_id_23d1badc14; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_supersedes_id_23d1badc14 ON public.recording_studio_billing_usage_corrections USING btree (supersedes_id);

-- Name: idx_on_supersedes_id_44a28e5061; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_supersedes_id_44a28e5061 ON public.recording_studio_billing_usage_ledger_entries USING btree (supersedes_id);

-- Name: idx_on_supersedes_id_d934e98c73; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_supersedes_id_d934e98c73 ON public.recording_studio_billing_tax_calculations USING btree (supersedes_id);

-- Name: idx_on_target_product_recording_id_2d78d41b32; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_target_product_recording_id_2d78d41b32 ON public.recording_studio_billing_product_rules USING btree (target_product_recording_id);

-- Name: idx_on_tax_calculation_id_957ee81be9; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_tax_calculation_id_957ee81be9 ON public.recording_studio_billing_usage_corrections USING btree (tax_calculation_id);

-- Name: idx_on_usage_allocation_id_2b30897f0c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_allocation_id_2b30897f0c ON public.recording_studio_billing_usage_corrections USING btree (usage_allocation_id);

-- Name: idx_on_usage_allocation_id_796b8d3d79; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_allocation_id_796b8d3d79 ON public.recording_studio_billing_usage_ledger_entries USING btree (usage_allocation_id);

-- Name: idx_on_usage_allocation_id_d1a92c7097; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_allocation_id_d1a92c7097 ON public.recording_studio_billing_overage_calculations USING btree (usage_allocation_id);

-- Name: idx_on_usage_allocation_id_db22072467; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_allocation_id_db22072467 ON public.recording_studio_billing_usage_credit_allocations USING btree (usage_allocation_id);

-- Name: idx_on_usage_credit_grant_id_40ac495e1d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_credit_grant_id_40ac495e1d ON public.recording_studio_billing_usage_credit_allocations USING btree (usage_credit_grant_id);

-- Name: idx_on_usage_credit_grant_id_47564c5c68; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_credit_grant_id_47564c5c68 ON public.recording_studio_billing_usage_ledger_entries USING btree (usage_credit_grant_id);

-- Name: idx_on_usage_event_id_5ee4df7b33; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_event_id_5ee4df7b33 ON public.recording_studio_billing_credit_ledger_entries USING btree (usage_event_id);

-- Name: idx_on_usage_period_id_3387c0b67f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_period_id_3387c0b67f ON public.recording_studio_billing_rated_usage_settlements USING btree (usage_period_id);

-- Name: idx_on_usage_period_id_540044dcc8; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_period_id_540044dcc8 ON public.recording_studio_billing_usage_ledger_entries USING btree (usage_period_id);

-- Name: idx_on_usage_period_id_94c38fef2e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_period_id_94c38fef2e ON public.recording_studio_billing_usage_allocations USING btree (usage_period_id);

-- Name: idx_on_usage_period_id_e3225ce305; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_period_id_e3225ce305 ON public.recording_studio_billing_usage_allowance_policies USING btree (usage_period_id);

-- Name: idx_on_usage_unit_recording_id_20bbb0eead; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_unit_recording_id_20bbb0eead ON public.recording_studio_billing_meters USING btree (usage_unit_recording_id);

-- Name: idx_on_usage_unit_recording_id_676a199a57; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_unit_recording_id_676a199a57 ON public.recording_studio_billing_cost_rates USING btree (usage_unit_recording_id);

-- Name: idx_on_usage_unit_recording_id_737a9cb844; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_unit_recording_id_737a9cb844 ON public.recording_studio_billing_rates USING btree (usage_unit_recording_id);

-- Name: idx_on_usage_unit_recording_id_9e76a066d4; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_usage_unit_recording_id_9e76a066d4 ON public.recording_studio_billing_overage_prices USING btree (usage_unit_recording_id);

-- Name: idx_rs_billing_account_root_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_account_root_history ON public.recording_studio_billing_accounts USING btree (root_recording_id);

-- Name: idx_rs_billing_adjustment_intent_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_adjustment_intent_idempotency ON public.recording_studio_billing_adjustment_intents USING btree (root_recording_id, local_idempotency_key);

-- Name: idx_rs_billing_adjustment_projection; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_adjustment_projection ON public.recording_studio_billing_financial_adjustments USING btree (adjustment_intent_id);

-- Name: idx_rs_billing_admin_root_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_admin_root_history ON public.recording_studio_billing_billing_admins USING btree (root_recording_id);

-- Name: idx_rs_billing_checkout_attempt_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_checkout_attempt_number ON public.recording_studio_billing_checkout_attempts USING btree (checkout_intent_id, attempt_number);

-- Name: idx_rs_billing_checkout_intent_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_checkout_intent_idempotency ON public.recording_studio_billing_checkout_intents USING btree (root_recording_id, local_idempotency_key);

-- Name: idx_rs_billing_checkout_items_option; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_checkout_items_option ON public.recording_studio_billing_checkout_intent_items USING btree (checkout_intent_id, billing_option_recording_id);

-- Name: idx_rs_billing_command_attempt_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_command_attempt_number ON public.recording_studio_billing_financial_command_attempts USING btree (financial_command_id, attempt_number);

-- Name: idx_rs_billing_commands_local_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_commands_local_idempotency ON public.recording_studio_billing_financial_commands USING btree (root_recording_id, local_idempotency_key);

-- Name: idx_rs_billing_commands_operation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_commands_operation ON public.recording_studio_billing_financial_commands USING btree (operation_id);

-- Name: idx_rs_billing_commands_pending_work; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_commands_pending_work ON public.recording_studio_billing_financial_commands USING btree (created_at) WHERE ((state)::text = 'pending'::text);

-- Name: idx_rs_billing_commands_provider_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_commands_provider_idempotency ON public.recording_studio_billing_financial_commands USING btree (provider_idempotency_key);

-- Name: idx_rs_billing_commands_reconciliation_work; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_commands_reconciliation_work ON public.recording_studio_billing_financial_commands USING btree (updated_at) WHERE (((state)::text = 'requires_reconciliation'::text) OR ((reconciliation_state)::text = 'pending'::text));

-- Name: idx_rs_billing_commands_stale_processing; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_commands_stale_processing ON public.recording_studio_billing_financial_commands USING btree (lease_expires_at) WHERE ((state)::text = 'processing'::text);

-- Name: idx_rs_billing_credit_debit_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_credit_debit_idempotency ON public.recording_studio_billing_credit_ledger_entries USING btree (root_recording_id, idempotency_key) WHERE ((direction)::text = 'debit'::text);

-- Name: idx_rs_billing_credit_ledger_balance; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_credit_ledger_balance ON public.recording_studio_billing_credit_ledger_entries USING btree (root_recording_id, account_recording_id, credit_key);

-- Name: idx_rs_billing_credit_ledger_effect_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_credit_ledger_effect_key ON public.recording_studio_billing_credit_ledger_entries USING btree (purchase_effect_id, credit_key);

-- Name: idx_rs_billing_credit_ledger_usage_event; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_credit_ledger_usage_event ON public.recording_studio_billing_credit_ledger_entries USING btree (usage_event_id);

-- Name: idx_rs_billing_entitlement_grant_source_feature; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_entitlement_grant_source_feature ON public.recording_studio_billing_entitlement_grants USING btree (root_recording_id, source_type, source_id, feature_key);

-- Name: idx_rs_billing_entitlement_grants_access; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_entitlement_grants_access ON public.recording_studio_billing_entitlement_grants USING btree (root_recording_id, account_recording_id, feature_key);

-- Name: idx_rs_billing_meter_aggregation_input; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_meter_aggregation_input ON public.recording_studio_billing_meter_aggregations USING btree (root_recording_id, account_recording_id, meter_recording_id, window_starts_at, window_ends_at, manifest_digest, input_digest);

-- Name: idx_rs_billing_one_account_per_root; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_one_account_per_root ON public.recording_studio_recordings USING btree (root_recording_id) WHERE ((recordable_type)::text = 'RecordingStudioBilling::Account'::text);

-- Name: idx_rs_billing_one_admin_per_root; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_one_admin_per_root ON public.recording_studio_recordings USING btree (root_recording_id) WHERE ((recordable_type)::text = 'RecordingStudioBilling::BillingAdmin'::text);

-- Name: idx_rs_billing_one_processing_attempt; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_one_processing_attempt ON public.recording_studio_billing_financial_command_attempts USING btree (financial_command_id) WHERE (((state)::text = 'processing'::text) AND (completed_at IS NULL));

-- Name: idx_rs_billing_overage_calculation_allocation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_overage_calculation_allocation ON public.recording_studio_billing_overage_calculations USING btree (usage_allocation_id);

-- Name: idx_rs_billing_payment_command; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_payment_command ON public.recording_studio_billing_payments USING btree (financial_command_id);

-- Name: idx_rs_billing_plan_update_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_plan_update_idempotency ON public.recording_studio_billing_plan_updates USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);

-- Name: idx_rs_billing_plan_update_run_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_plan_update_run_idempotency ON public.recording_studio_billing_plan_update_runs USING btree (plan_update_id, idempotency_key);

-- Name: idx_rs_billing_plan_update_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_plan_update_subscription ON public.recording_studio_billing_plan_update_applications USING btree (plan_update_id, subscription_id);

-- Name: idx_rs_billing_provider_reference_scoped_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_provider_reference_scoped_identity ON public.recording_studio_billing_provider_references USING btree (provider_account_recording_id, environment, remote_type, remote_id);

-- Name: idx_rs_billing_purchase_checkout_item; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_purchase_checkout_item ON public.recording_studio_billing_purchases USING btree (checkout_intent_item_id);

-- Name: idx_rs_billing_purchase_effect_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_purchase_effect_idempotency ON public.recording_studio_billing_purchase_effects USING btree (root_recording_id, idempotency_key);

-- Name: idx_rs_billing_rated_usage_aggregation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_rated_usage_aggregation ON public.recording_studio_billing_rated_usages USING btree (meter_aggregation_id);

-- Name: idx_rs_billing_reconciliation_issue_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_reconciliation_issue_history ON public.recording_studio_billing_reconciliation_issues USING btree (financial_command_id, kind, created_at);

-- Name: idx_rs_billing_reconciliation_runs; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_reconciliation_runs ON public.recording_studio_billing_reconciliation_records USING btree (financial_command_id, created_at);

-- Name: idx_rs_billing_refund_intent_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_refund_intent_idempotency ON public.recording_studio_billing_refund_intents USING btree (root_recording_id, local_idempotency_key);

-- Name: idx_rs_billing_refund_projection; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_refund_projection ON public.recording_studio_billing_refunds USING btree (refund_intent_id);

-- Name: idx_rs_billing_settlement_command; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_settlement_command ON public.recording_studio_billing_rated_usage_settlements USING btree (financial_command_id);

-- Name: idx_rs_billing_subscription_change_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscription_change_idempotency ON public.recording_studio_billing_subscription_change_intents USING btree (root_recording_id, local_idempotency_key);

-- Name: idx_rs_billing_subscription_execution_group; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscription_execution_group ON public.recording_studio_billing_subscriptions USING btree (root_recording_id, account_recording_id, execution_group_fingerprint);

-- Name: idx_rs_billing_subscription_item_checkout_item; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscription_item_checkout_item ON public.recording_studio_billing_subscription_item_versions USING btree (checkout_intent_item_id);

-- Name: idx_rs_billing_subscription_item_line; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscription_item_line ON public.recording_studio_billing_subscription_items USING btree (subscription_id, line_key);

-- Name: idx_rs_billing_subscription_item_line_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscription_item_line_version ON public.recording_studio_billing_subscription_item_versions USING btree (subscription_id, line_key, version_number);

-- Name: idx_rs_billing_subscription_item_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscription_item_version ON public.recording_studio_billing_subscription_item_versions USING btree (subscription_item_id, version_number);

-- Name: idx_rs_billing_subscriptions_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscriptions_identifier ON public.recording_studio_billing_subscriptions USING btree (identifier);

-- Name: idx_rs_billing_tax_command_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_tax_command_revision ON public.recording_studio_billing_tax_calculations USING btree (financial_command_id, revision_number);

-- Name: idx_rs_billing_tax_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_tax_fingerprint ON public.recording_studio_billing_tax_calculations USING btree (request_fingerprint);

-- Name: idx_rs_billing_tax_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_tax_idempotency ON public.recording_studio_billing_tax_calculations USING btree (root_recording_id, idempotency_key, revision_number);

-- Name: idx_rs_billing_unresolved_webhook_receipt; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_unresolved_webhook_receipt ON public.recording_studio_billing_reconciliation_issues USING btree (provider_account_recording_id, environment, inbound_event_id, handler_name, action_version, kind) WHERE (financial_command_id IS NULL);

-- Name: idx_rs_billing_usage_allocation_rated_usage; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_usage_allocation_rated_usage ON public.recording_studio_billing_usage_allocations USING btree (rated_usage_id);

-- Name: idx_rs_billing_usage_allowance_policy; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_usage_allowance_policy ON public.recording_studio_billing_usage_allowance_policies USING btree (usage_period_id, usage_key, effective_at);

-- Name: idx_rs_billing_usage_correction_command; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_usage_correction_command ON public.recording_studio_billing_usage_corrections USING btree (financial_command_id) WHERE (financial_command_id IS NOT NULL);

-- Name: idx_rs_billing_usage_correction_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_usage_correction_kind ON public.recording_studio_billing_usage_corrections USING btree (usage_allocation_id, correction_kind);

-- Name: idx_rs_billing_usage_credit_allocation_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_usage_credit_allocation_unique ON public.recording_studio_billing_usage_credit_allocations USING btree (usage_allocation_id, usage_credit_grant_id);

-- Name: idx_rs_billing_usage_credit_grant_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_usage_credit_grant_source ON public.recording_studio_billing_usage_credit_grants USING btree (root_recording_id, source_key);

-- Name: idx_rs_billing_usage_credit_grants_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_usage_credit_grants_active ON public.recording_studio_billing_usage_credit_grants USING btree (root_recording_id, account_recording_id, credit_key, effective_at, expires_at);

-- Name: idx_rs_billing_usage_event_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_usage_event_idempotency ON public.recording_studio_billing_usage_events USING btree (root_recording_id, idempotency_key);

-- Name: idx_rs_billing_usage_event_total; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_usage_event_total ON public.recording_studio_billing_usage_events USING btree (root_recording_id, account_recording_id, usage_key, occurred_at);

-- Name: idx_rs_billing_usage_ledger_allocation_entry; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_usage_ledger_allocation_entry ON public.recording_studio_billing_usage_ledger_entries USING btree (usage_allocation_id, entry_kind, usage_credit_grant_id) WHERE (usage_allocation_id IS NOT NULL);

-- Name: idx_rs_billing_usage_ledger_period_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_usage_ledger_period_sequence ON public.recording_studio_billing_usage_ledger_entries USING btree (usage_period_id, sequence);

-- Name: idx_rs_billing_usage_period_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_usage_period_scope ON public.recording_studio_billing_usage_periods USING btree (root_recording_id, account_recording_id, usage_key, starts_at, ends_at);

-- Name: idx_rs_billing_usage_settlement_period; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_usage_settlement_period ON public.recording_studio_billing_rated_usage_settlements USING btree (usage_period_id);

-- Name: idx_rs_billing_webhook_effect_receipt_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_webhook_effect_receipt_identity ON public.recording_studio_billing_webhook_effects USING btree (inbound_event_id, provider_account_recording_id, environment, handler_name, action_version);

-- Name: index_recording_studio_billing_invoice_lines_on_invoice_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_invoice_lines_on_invoice_id ON public.recording_studio_billing_invoice_lines USING btree (invoice_id);

-- Name: index_recording_studio_billing_invoices_on_purchase_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_invoices_on_purchase_id ON public.recording_studio_billing_invoices USING btree (purchase_id);

-- Name: index_recording_studio_billing_invoices_on_root_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_invoices_on_root_recording_id ON public.recording_studio_billing_invoices USING btree (root_recording_id);

-- Name: index_recording_studio_billing_invoices_on_subscription_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_invoices_on_subscription_id ON public.recording_studio_billing_invoices USING btree (subscription_id);

-- Name: index_recording_studio_billing_payments_on_invoice_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_payments_on_invoice_id ON public.recording_studio_billing_payments USING btree (invoice_id);

-- Name: index_recording_studio_billing_payments_on_root_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_payments_on_root_recording_id ON public.recording_studio_billing_payments USING btree (root_recording_id);

-- Name: index_recording_studio_billing_prices_on_market_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_prices_on_market_recording_id ON public.recording_studio_billing_prices USING btree (market_recording_id);

-- Name: index_recording_studio_billing_purchase_effects_on_purchase_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_purchase_effects_on_purchase_id ON public.recording_studio_billing_purchase_effects USING btree (purchase_id);

-- Name: index_recording_studio_billing_purchases_on_checkout_intent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_purchases_on_checkout_intent_id ON public.recording_studio_billing_purchases USING btree (checkout_intent_id);

-- Name: index_recording_studio_billing_purchases_on_root_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_purchases_on_root_recording_id ON public.recording_studio_billing_purchases USING btree (root_recording_id);

-- Name: index_recording_studio_billing_rates_on_rate_card_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_rates_on_rate_card_recording_id ON public.recording_studio_billing_rates USING btree (rate_card_recording_id);

-- Name: index_recording_studio_billing_refund_intents_on_payment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_refund_intents_on_payment_id ON public.recording_studio_billing_refund_intents USING btree (payment_id);

-- Name: index_recording_studio_billing_refunds_on_financial_command_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_refunds_on_financial_command_id ON public.recording_studio_billing_refunds USING btree (financial_command_id);

-- Name: index_recording_studio_billing_refunds_on_payment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_refunds_on_payment_id ON public.recording_studio_billing_refunds USING btree (payment_id);

-- Name: index_recording_studio_billing_refunds_on_refund_intent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_refunds_on_refund_intent_id ON public.recording_studio_billing_refunds USING btree (refund_intent_id);

-- Name: rs_billing_publication_candidate_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX rs_billing_publication_candidate_identity ON public.recording_studio_billing_commercial_publication_candidates USING btree (root_recording_id, effective_at);

-- Name: rs_billing_publication_candidates_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX rs_billing_publication_candidates_digest ON public.recording_studio_billing_commercial_publication_candidates USING btree (candidate_digest);

-- Name: recording_studio_billing_billing_options recording_studio_billing_billing_options_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_billing_options_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_billing_options FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::BillingOption');

-- Name: recording_studio_billing_billing_options recording_studio_billing_billing_options_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_billing_options_validate_publication AFTER INSERT ON public.recording_studio_billing_billing_options DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::BillingOption');

-- Name: recording_studio_billing_cost_cards recording_studio_billing_cost_cards_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_cost_cards_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_cost_cards FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::CostCard');

-- Name: recording_studio_billing_cost_cards recording_studio_billing_cost_cards_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_cost_cards_validate_publication AFTER INSERT ON public.recording_studio_billing_cost_cards DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::CostCard');

-- Name: recording_studio_billing_cost_rates recording_studio_billing_cost_rates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_cost_rates_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_cost_rates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::CostRate');

-- Name: recording_studio_billing_cost_rates recording_studio_billing_cost_rates_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_cost_rates_validate_publication AFTER INSERT ON public.recording_studio_billing_cost_rates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::CostRate');

-- Name: recording_studio_billing_feature_overrides recording_studio_billing_feature_overrides_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_feature_overrides_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_feature_overrides FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::FeatureOverride');

-- Name: recording_studio_billing_feature_overrides recording_studio_billing_feature_overrides_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_feature_overrides_validate_publication AFTER INSERT ON public.recording_studio_billing_feature_overrides DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::FeatureOverride');

-- Name: recording_studio_billing_features recording_studio_billing_features_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_features_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_features FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Feature');

-- Name: recording_studio_billing_features recording_studio_billing_features_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_features_validate_publication AFTER INSERT ON public.recording_studio_billing_features DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Feature');

-- Name: recording_studio_billing_markets recording_studio_billing_markets_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_markets_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_markets FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Market');

-- Name: recording_studio_billing_markets recording_studio_billing_markets_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_markets_validate_publication AFTER INSERT ON public.recording_studio_billing_markets DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Market');

-- Name: recording_studio_billing_meters recording_studio_billing_meters_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_meters_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_meters FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Meter');

-- Name: recording_studio_billing_meters recording_studio_billing_meters_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_meters_validate_publication AFTER INSERT ON public.recording_studio_billing_meters DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Meter');

-- Name: recording_studio_billing_overage_prices recording_studio_billing_overage_prices_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_overage_prices_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_overage_prices FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::OveragePrice');

-- Name: recording_studio_billing_overage_prices recording_studio_billing_overage_prices_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_overage_prices_validate_publication AFTER INSERT ON public.recording_studio_billing_overage_prices DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::OveragePrice');

-- Name: recording_studio_billing_plan_updates recording_studio_billing_plan_updates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_plan_updates_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_plan_updates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::PlanUpdate');

-- Name: recording_studio_billing_plan_updates recording_studio_billing_plan_updates_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_plan_updates_validate_publication AFTER INSERT ON public.recording_studio_billing_plan_updates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::PlanUpdate');

-- Name: recording_studio_billing_prices recording_studio_billing_prices_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_prices_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_prices FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Price');

-- Name: recording_studio_billing_prices recording_studio_billing_prices_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_prices_validate_publication AFTER INSERT ON public.recording_studio_billing_prices DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Price');

-- Name: recording_studio_billing_product_rules recording_studio_billing_product_rules_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_product_rules_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_product_rules FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::ProductRule');

-- Name: recording_studio_billing_product_rules recording_studio_billing_product_rules_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_product_rules_validate_publication AFTER INSERT ON public.recording_studio_billing_product_rules DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::ProductRule');

-- Name: recording_studio_billing_products recording_studio_billing_products_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_products_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_products FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Product');

-- Name: recording_studio_billing_products recording_studio_billing_products_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_products_validate_publication AFTER INSERT ON public.recording_studio_billing_products DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Product');

-- Name: recording_studio_billing_provider_accounts recording_studio_billing_provider_accounts_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_provider_accounts_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_provider_accounts FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::ProviderAccount');

-- Name: recording_studio_billing_provider_accounts recording_studio_billing_provider_accounts_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_provider_accounts_validate_publication AFTER INSERT ON public.recording_studio_billing_provider_accounts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::ProviderAccount');

-- Name: recording_studio_billing_rate_cards recording_studio_billing_rate_cards_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_rate_cards_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_rate_cards FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::RateCard');

-- Name: recording_studio_billing_rate_cards recording_studio_billing_rate_cards_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_rate_cards_validate_publication AFTER INSERT ON public.recording_studio_billing_rate_cards DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::RateCard');

-- Name: recording_studio_billing_rates recording_studio_billing_rates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_rates_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_rates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Rate');

-- Name: recording_studio_billing_rates recording_studio_billing_rates_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_rates_validate_publication AFTER INSERT ON public.recording_studio_billing_rates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Rate');

-- Name: recording_studio_billing_usage_units recording_studio_billing_usage_units_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_usage_units_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_usage_units FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::UsageUnit');

-- Name: recording_studio_billing_usage_units recording_studio_billing_usage_units_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_usage_units_validate_publication AFTER INSERT ON public.recording_studio_billing_usage_units DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::UsageUnit');

-- Name: recording_studio_billing_financial_adjustments rs_billing_adjustment_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_adjustment_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_financial_adjustments FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_projection();

-- Name: recording_studio_billing_adjustment_intents rs_billing_adjustment_intent_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_adjustment_intent_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_adjustment_intents FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_financial_lifecycle_authority();

-- Name: recording_studio_billing_commercial_publication_candidates rs_billing_candidates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_candidates_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_commercial_publication_candidates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_candidate_history();

-- Name: recording_studio_billing_checkout_attempts rs_billing_checkout_attempt_command_correlation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_attempt_command_correlation BEFORE INSERT OR UPDATE OF financial_command_attempt_id ON public.recording_studio_billing_checkout_attempts FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_checkout_attempt_command_correlation();

-- Name: recording_studio_billing_checkout_attempts rs_billing_checkout_attempt_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_attempt_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_checkout_attempts FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_checkout_attempt();

-- Name: recording_studio_billing_checkout_intents rs_billing_checkout_intent_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_intent_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_checkout_intents FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_checkout_authority();

-- Name: recording_studio_billing_checkout_intents rs_billing_checkout_intent_command_binding; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_intent_command_binding BEFORE UPDATE OF financial_command_id ON public.recording_studio_billing_checkout_intents FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_checkout_command_binding();

-- Name: recording_studio_billing_checkout_intents rs_billing_checkout_intent_execution_state; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_intent_execution_state BEFORE UPDATE OF state ON public.recording_studio_billing_checkout_intents FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_checkout_execution_state();

-- Name: recording_studio_billing_checkout_intent_items rs_billing_checkout_item_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_item_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_checkout_intent_items FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_checkout_item();

-- Name: recording_studio_billing_financial_command_attempts rs_billing_command_attempt_consistency_from_attempt; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER rs_billing_command_attempt_consistency_from_attempt AFTER INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_financial_command_attempts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_command_attempt_consistency();

-- Name: recording_studio_billing_financial_commands rs_billing_command_attempt_consistency_from_command; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER rs_billing_command_attempt_consistency_from_command AFTER INSERT OR UPDATE ON public.recording_studio_billing_financial_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_command_attempt_consistency();

-- Name: recording_studio_billing_financial_command_attempts rs_billing_command_attempt_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_command_attempt_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_financial_command_attempts FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_command_attempt();

-- Name: recording_studio_billing_credit_ledger_entries rs_billing_credit_ledger_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_credit_ledger_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_credit_ledger_entries FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_credit_ledger_entry();

-- Name: recording_studio_billing_entitlement_grants rs_billing_entitlement_grant_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_entitlement_grant_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_entitlement_grants FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_entitlement_projection();

-- Name: recording_studio_billing_financial_commands rs_billing_financial_command_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_financial_command_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_financial_commands FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_command_authority();

-- Name: recording_studio_billing_financial_commands rs_billing_financial_command_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_financial_command_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_financial_commands FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_financial_command();

-- Name: recording_studio_billing_invoices rs_billing_invoice_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_invoice_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_invoices FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_financial_lifecycle_authority();

-- Name: recording_studio_billing_invoices rs_billing_invoice_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_invoice_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_invoices FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_projection();

-- Name: recording_studio_billing_invoice_lines rs_billing_invoice_line_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_invoice_line_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_invoice_lines FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_projection();

-- Name: recording_studio_billing_commercial_manifests rs_billing_manifests_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_manifests_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_commercial_manifests FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_manifest_history();

-- Name: recording_studio_billing_meter_aggregations rs_billing_meter_aggregation_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_meter_aggregation_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_meter_aggregations FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_meter_aggregation();

-- Name: recording_studio_billing_overage_calculations rs_billing_overage_calculation_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_overage_calculation_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_overage_calculations FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_overage_calculation();

-- Name: recording_studio_billing_payment_allocations rs_billing_payment_allocation_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_payment_allocation_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_payment_allocations FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_financial_lifecycle_authority();

-- Name: recording_studio_billing_payment_allocations rs_billing_payment_allocation_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_payment_allocation_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_payment_allocations FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_projection();

-- Name: recording_studio_billing_payments rs_billing_payment_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_payment_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_payments FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_financial_lifecycle_authority();

-- Name: recording_studio_billing_payments rs_billing_payment_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_payment_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_payments FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_projection();

-- Name: recording_studio_billing_plan_update_applications rs_billing_plan_update_application_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_plan_update_application_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_plan_update_applications FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_financial_lifecycle_authority();

-- Name: recording_studio_billing_provider_references rs_billing_provider_reference_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_provider_reference_authority BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_provider_references FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_provider_reference();

-- Name: recording_studio_billing_purchases rs_billing_purchase_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_purchase_authority BEFORE INSERT ON public.recording_studio_billing_purchases FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_lifecycle_projection();

-- Name: recording_studio_billing_purchase_effects rs_billing_purchase_effect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_purchase_effect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_purchase_effects FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_purchase_effect();

-- Name: recording_studio_billing_purchases rs_billing_purchase_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_purchase_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_purchases FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_purchase();

-- Name: recording_studio_billing_rated_usages rs_billing_rated_usage_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_rated_usage_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_rated_usages FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_rated_usage();

-- Name: recording_studio_billing_rated_usage_settlements rs_billing_rated_usage_settlement_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_rated_usage_settlement_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_rated_usage_settlements FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_rated_usage_settlement();

-- Name: recording_studio_billing_reconciliation_issues rs_billing_reconciliation_issue_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_reconciliation_issue_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_reconciliation_issues FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_reconciliation_history();

-- Name: recording_studio_billing_reconciliation_records rs_billing_reconciliation_record_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_reconciliation_record_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_reconciliation_records FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_reconciliation_history();

-- Name: recording_studio_billing_refunds rs_billing_refund_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_refund_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_refunds FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_projection();

-- Name: recording_studio_billing_refund_intents rs_billing_refund_intent_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_refund_intent_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_refund_intents FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_financial_lifecycle_authority();

-- Name: recording_studio_billing_subscriptions rs_billing_subscription_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_subscription_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_subscriptions FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_lifecycle_projection();

-- Name: recording_studio_billing_subscription_change_intents rs_billing_subscription_change_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_subscription_change_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_subscription_change_intents FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_lifecycle_authority();

-- Name: recording_studio_billing_subscription_items rs_billing_subscription_item_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_subscription_item_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_subscription_items FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_lifecycle_authority();

-- Name: recording_studio_billing_subscription_item_versions rs_billing_subscription_item_version_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_subscription_item_version_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_subscription_item_versions FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_lifecycle_authority();

-- Name: recording_studio_billing_subscription_item_versions rs_billing_subscription_item_version_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_subscription_item_version_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_subscription_item_versions FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_subscription_item_version();

-- Name: recording_studio_billing_subscriptions rs_billing_subscription_lifecycle; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_subscription_lifecycle BEFORE DELETE OR UPDATE ON public.recording_studio_billing_subscriptions FOR EACH ROW EXECUTE FUNCTION public.rs_billing_subscription_lifecycle();

-- Name: recording_studio_billing_tax_calculations rs_billing_tax_calculation_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_tax_calculation_authority BEFORE INSERT ON public.recording_studio_billing_tax_calculations FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_tax_authority();

-- Name: recording_studio_billing_tax_calculations rs_billing_tax_calculation_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_tax_calculation_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_tax_calculations FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_tax_calculation();

-- Name: recording_studio_billing_tax_calculations rs_billing_tax_manifest_set_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_tax_manifest_set_authority BEFORE INSERT ON public.recording_studio_billing_tax_calculations FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_tax_manifest_set();

-- Name: recording_studio_billing_usage_corrections rs_billing_usage_correction_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_usage_correction_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_usage_corrections FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_usage_correction();

-- Name: recording_studio_billing_usage_credit_grants rs_billing_usage_credit_grant_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_usage_credit_grant_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_usage_credit_grants FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_usage_credit_grant();

-- Name: recording_studio_billing_usage_events rs_billing_usage_event_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_usage_event_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_usage_events FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_usage_event();

-- Name: recording_studio_billing_usage_ledger_entries rs_billing_usage_ledger_entry_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_usage_ledger_entry_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_usage_ledger_entries FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_usage_ledger_entry();

-- Name: recording_studio_billing_payment_allocations fk_rails_03719c9cf2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_payment_allocations
    ADD CONSTRAINT fk_rails_03719c9cf2 FOREIGN KEY (payment_id) REFERENCES public.recording_studio_billing_payments(id);

-- Name: recording_studio_billing_invoices fk_rails_05dec68c81; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_invoices
    ADD CONSTRAINT fk_rails_05dec68c81 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_rated_usage_settlements fk_rails_0753a25392; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usage_settlements
    ADD CONSTRAINT fk_rails_0753a25392 FOREIGN KEY (rated_usage_id) REFERENCES public.recording_studio_billing_rated_usages(id);

-- Name: recording_studio_billing_payments fk_rails_07f18c7620; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_payments
    ADD CONSTRAINT fk_rails_07f18c7620 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_credit_ledger_entries fk_rails_0eb965f4e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_credit_ledger_entries
    ADD CONSTRAINT fk_rails_0eb965f4e9 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_provider_accounts fk_rails_1247aa36a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_provider_accounts
    ADD CONSTRAINT fk_rails_1247aa36a0 FOREIGN KEY (billing_admin_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_plan_update_applications fk_rails_138729a8ec; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_update_applications
    ADD CONSTRAINT fk_rails_138729a8ec FOREIGN KEY (subscription_change_intent_id) REFERENCES public.recording_studio_billing_subscription_change_intents(id);

-- Name: recording_studio_billing_feature_overrides fk_rails_17bde42a64; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_feature_overrides
    ADD CONSTRAINT fk_rails_17bde42a64 FOREIGN KEY (feature_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_ledger_entries fk_rails_1895ea5d94; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_ledger_entries
    ADD CONSTRAINT fk_rails_1895ea5d94 FOREIGN KEY (supersedes_id) REFERENCES public.recording_studio_billing_usage_ledger_entries(id);

-- Name: recording_studio_billing_entitlement_grants fk_rails_1b30f1de5f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_entitlement_grants
    ADD CONSTRAINT fk_rails_1b30f1de5f FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_provider_references fk_rails_1bdf7ac827; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_provider_references
    ADD CONSTRAINT fk_rails_1bdf7ac827 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_usage_corrections fk_rails_200459b147; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_corrections
    ADD CONSTRAINT fk_rails_200459b147 FOREIGN KEY (supersedes_id) REFERENCES public.recording_studio_billing_usage_corrections(id);

-- Name: recording_studio_billing_rated_usages fk_rails_21585faf73; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usages
    ADD CONSTRAINT fk_rails_21585faf73 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_subscription_item_versions fk_rails_2182831985; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT fk_rails_2182831985 FOREIGN KEY (subscription_item_id) REFERENCES public.recording_studio_billing_subscription_items(id);

-- Name: recording_studio_billing_rates fk_rails_22d4fb3576; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rates
    ADD CONSTRAINT fk_rails_22d4fb3576 FOREIGN KEY (rate_card_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_credit_grants fk_rails_27aec1fa25; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_credit_grants
    ADD CONSTRAINT fk_rails_27aec1fa25 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_allowance_policies fk_rails_2c0d836762; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_allowance_policies
    ADD CONSTRAINT fk_rails_2c0d836762 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_purchases fk_rails_2db0688675; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchases
    ADD CONSTRAINT fk_rails_2db0688675 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_checkout_intents fk_rails_2ec9aa65bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intents
    ADD CONSTRAINT fk_rails_2ec9aa65bd FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_adjustment_intents fk_rails_3187ff5d54; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_adjustment_intents
    ADD CONSTRAINT fk_rails_3187ff5d54 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_tax_calculations fk_rails_31eed02146; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT fk_rails_31eed02146 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_billing_options fk_rails_33726a97d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_billing_options
    ADD CONSTRAINT fk_rails_33726a97d6 FOREIGN KEY (product_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_payments fk_rails_3cf8ecc046; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_payments
    ADD CONSTRAINT fk_rails_3cf8ecc046 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_purchase_effects fk_rails_3e3b69f431; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchase_effects
    ADD CONSTRAINT fk_rails_3e3b69f431 FOREIGN KEY (purchase_id) REFERENCES public.recording_studio_billing_purchases(id);

-- Name: recording_studio_billing_financial_adjustments fk_rails_403ed1a454; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_adjustments
    ADD CONSTRAINT fk_rails_403ed1a454 FOREIGN KEY (invoice_id) REFERENCES public.recording_studio_billing_invoices(id);

-- Name: recording_studio_billing_invoice_lines fk_rails_40a3be08d4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_invoice_lines
    ADD CONSTRAINT fk_rails_40a3be08d4 FOREIGN KEY (invoice_id) REFERENCES public.recording_studio_billing_invoices(id);

-- Name: recording_studio_billing_purchases fk_rails_436859f7d5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchases
    ADD CONSTRAINT fk_rails_436859f7d5 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_invoices fk_rails_437dc370ca; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_invoices
    ADD CONSTRAINT fk_rails_437dc370ca FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_checkout_intent_items fk_rails_454ae16426; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intent_items
    ADD CONSTRAINT fk_rails_454ae16426 FOREIGN KEY (checkout_intent_id) REFERENCES public.recording_studio_billing_checkout_intents(id);

-- Name: recording_studio_billing_financial_commands fk_rails_45f2293813; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_commands
    ADD CONSTRAINT fk_rails_45f2293813 FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_purchase_effects fk_rails_481999b1e3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchase_effects
    ADD CONSTRAINT fk_rails_481999b1e3 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_subscription_item_versions fk_rails_4992812ca8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT fk_rails_4992812ca8 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_rated_usage_settlements fk_rails_49d937bf87; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usage_settlements
    ADD CONSTRAINT fk_rails_49d937bf87 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_purchase_effects fk_rails_4b371c645a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchase_effects
    ADD CONSTRAINT fk_rails_4b371c645a FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_subscription_change_intents fk_rails_4b64fb3f93; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_change_intents
    ADD CONSTRAINT fk_rails_4b64fb3f93 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_corrections fk_rails_4d4ec85764; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_corrections
    ADD CONSTRAINT fk_rails_4d4ec85764 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_plan_updates fk_rails_511ec0e839; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_updates
    ADD CONSTRAINT fk_rails_511ec0e839 FOREIGN KEY (billing_option_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_allowance_policies fk_rails_52c3d91cb4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_allowance_policies
    ADD CONSTRAINT fk_rails_52c3d91cb4 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_rated_usages fk_rails_54b225ad68; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usages
    ADD CONSTRAINT fk_rails_54b225ad68 FOREIGN KEY (meter_aggregation_id) REFERENCES public.recording_studio_billing_meter_aggregations(id);

-- Name: recording_studio_billing_invoices fk_rails_57ef7bcb9f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_invoices
    ADD CONSTRAINT fk_rails_57ef7bcb9f FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_tax_calculations fk_rails_580f212427; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT fk_rails_580f212427 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_plan_update_applications fk_rails_58986bbdeb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_update_applications
    ADD CONSTRAINT fk_rails_58986bbdeb FOREIGN KEY (plan_update_run_id) REFERENCES public.recording_studio_billing_plan_update_runs(id);

-- Name: recording_studio_billing_subscriptions fk_rails_590163cfec; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscriptions
    ADD CONSTRAINT fk_rails_590163cfec FOREIGN KEY (market_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_subscription_item_versions fk_rails_59234eacda; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT fk_rails_59234eacda FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_financial_commands fk_rails_5a6dd935b1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_commands
    ADD CONSTRAINT fk_rails_5a6dd935b1 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_rates fk_rails_5c82417e3e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rates
    ADD CONSTRAINT fk_rails_5c82417e3e FOREIGN KEY (usage_unit_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_credit_grants fk_rails_5d84c55ced; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_credit_grants
    ADD CONSTRAINT fk_rails_5d84c55ced FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_cost_rates fk_rails_6180561f6f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_rates
    ADD CONSTRAINT fk_rails_6180561f6f FOREIGN KEY (cost_card_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_accounts fk_rails_618f9da784; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_accounts
    ADD CONSTRAINT fk_rails_618f9da784 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_billing_admins fk_rails_61d701f772; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_billing_admins
    ADD CONSTRAINT fk_rails_61d701f772 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_refunds fk_rails_6241d24d70; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_refunds
    ADD CONSTRAINT fk_rails_6241d24d70 FOREIGN KEY (refund_intent_id) REFERENCES public.recording_studio_billing_refund_intents(id);

-- Name: recording_studio_billing_prices fk_rails_62af4fe846; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_prices
    ADD CONSTRAINT fk_rails_62af4fe846 FOREIGN KEY (billing_option_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_reconciliation_issues fk_rails_6326faa349; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_reconciliation_issues
    ADD CONSTRAINT fk_rails_6326faa349 FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_credit_allocations fk_rails_65809eecc3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_credit_allocations
    ADD CONSTRAINT fk_rails_65809eecc3 FOREIGN KEY (usage_allocation_id) REFERENCES public.recording_studio_billing_usage_allocations(id);

-- Name: recording_studio_billing_adjustment_intents fk_rails_6849d3008f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_adjustment_intents
    ADD CONSTRAINT fk_rails_6849d3008f FOREIGN KEY (invoice_id) REFERENCES public.recording_studio_billing_invoices(id);

-- Name: recording_studio_billing_refund_intents fk_rails_6a522ae8d3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_refund_intents
    ADD CONSTRAINT fk_rails_6a522ae8d3 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_adjustment_intents fk_rails_6aa8855c04; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_adjustment_intents
    ADD CONSTRAINT fk_rails_6aa8855c04 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_events fk_rails_6f1eea0ab2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_events
    ADD CONSTRAINT fk_rails_6f1eea0ab2 FOREIGN KEY (late_usage_period_id) REFERENCES public.recording_studio_billing_usage_periods(id);

-- Name: recording_studio_billing_subscription_items fk_rails_6f3c6eb3c0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_items
    ADD CONSTRAINT fk_rails_6f3c6eb3c0 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_overage_prices fk_rails_71961e29ca; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_prices
    ADD CONSTRAINT fk_rails_71961e29ca FOREIGN KEY (usage_unit_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_prices fk_rails_71e092b121; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_prices
    ADD CONSTRAINT fk_rails_71e092b121 FOREIGN KEY (market_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_meters fk_rails_754812330d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_meters
    ADD CONSTRAINT fk_rails_754812330d FOREIGN KEY (usage_unit_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_credit_ledger_entries fk_rails_7582e03759; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_credit_ledger_entries
    ADD CONSTRAINT fk_rails_7582e03759 FOREIGN KEY (usage_event_id) REFERENCES public.recording_studio_billing_usage_events(id);

-- Name: recording_studio_billing_subscriptions fk_rails_770ec9da1e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscriptions
    ADD CONSTRAINT fk_rails_770ec9da1e FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_subscription_item_versions fk_rails_77212d5465; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT fk_rails_77212d5465 FOREIGN KEY (subscription_id) REFERENCES public.recording_studio_billing_subscriptions(id);

-- Name: recording_studio_billing_subscription_item_versions fk_rails_7ad7f1b975; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT fk_rails_7ad7f1b975 FOREIGN KEY (checkout_intent_id) REFERENCES public.recording_studio_billing_checkout_intents(id);

-- Name: recording_studio_billing_refunds fk_rails_7afc681b16; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_refunds
    ADD CONSTRAINT fk_rails_7afc681b16 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_credit_ledger_entries fk_rails_7c45c8481c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_credit_ledger_entries
    ADD CONSTRAINT fk_rails_7c45c8481c FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_purchases fk_rails_7f6c19f3a5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchases
    ADD CONSTRAINT fk_rails_7f6c19f3a5 FOREIGN KEY (checkout_intent_id) REFERENCES public.recording_studio_billing_checkout_intents(id);

-- Name: recording_studio_billing_entitlement_grants fk_rails_7f8dce0a7f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_entitlement_grants
    ADD CONSTRAINT fk_rails_7f8dce0a7f FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_cost_cards fk_rails_7fe81ededc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_cards
    ADD CONSTRAINT fk_rails_7fe81ededc FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_invoices fk_rails_8379195747; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_invoices
    ADD CONSTRAINT fk_rails_8379195747 FOREIGN KEY (subscription_id) REFERENCES public.recording_studio_billing_subscriptions(id);

-- Name: recording_studio_billing_usage_allocations fk_rails_83995afa71; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_allocations
    ADD CONSTRAINT fk_rails_83995afa71 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_plan_update_applications fk_rails_840dd3b60c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_update_applications
    ADD CONSTRAINT fk_rails_840dd3b60c FOREIGN KEY (subscription_id) REFERENCES public.recording_studio_billing_subscriptions(id);

-- Name: recording_studio_billing_invoices fk_rails_84e50e53b6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_invoices
    ADD CONSTRAINT fk_rails_84e50e53b6 FOREIGN KEY (purchase_id) REFERENCES public.recording_studio_billing_purchases(id);

-- Name: recording_studio_billing_financial_command_attempts fk_rails_87375cc605; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_command_attempts
    ADD CONSTRAINT fk_rails_87375cc605 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_tax_calculations fk_rails_896fceb34d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT fk_rails_896fceb34d FOREIGN KEY (commercial_manifest_id) REFERENCES public.recording_studio_billing_commercial_manifests(id);

-- Name: recording_studio_billing_usage_periods fk_rails_8b30316470; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_periods
    ADD CONSTRAINT fk_rails_8b30316470 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_overage_calculations fk_rails_8c0a89323f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_calculations
    ADD CONSTRAINT fk_rails_8c0a89323f FOREIGN KEY (overage_price_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_payments fk_rails_8e6bba275d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_payments
    ADD CONSTRAINT fk_rails_8e6bba275d FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_subscription_items fk_rails_907dd5e2ad; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_items
    ADD CONSTRAINT fk_rails_907dd5e2ad FOREIGN KEY (subscription_id) REFERENCES public.recording_studio_billing_subscriptions(id);

-- Name: recording_studio_billing_overage_prices fk_rails_9546dcb8cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_prices
    ADD CONSTRAINT fk_rails_9546dcb8cf FOREIGN KEY (billing_option_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_refund_intents fk_rails_97c28ba8db; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_refund_intents
    ADD CONSTRAINT fk_rails_97c28ba8db FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_subscriptions fk_rails_97d9baa876; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscriptions
    ADD CONSTRAINT fk_rails_97d9baa876 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_events fk_rails_98ba3ca398; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_events
    ADD CONSTRAINT fk_rails_98ba3ca398 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_checkout_intents fk_rails_9ad6795b60; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intents
    ADD CONSTRAINT fk_rails_9ad6795b60 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_webhook_effects fk_rails_9c6d3a6c42; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_webhook_effects
    ADD CONSTRAINT fk_rails_9c6d3a6c42 FOREIGN KEY (provider_reference_id) REFERENCES public.recording_studio_billing_provider_references(id);

-- Name: recording_studio_billing_features fk_rails_9eae67f745; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_features
    ADD CONSTRAINT fk_rails_9eae67f745 FOREIGN KEY (product_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_product_rules fk_rails_9eb3a96d12; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_product_rules
    ADD CONSTRAINT fk_rails_9eb3a96d12 FOREIGN KEY (product_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_refunds fk_rails_a02352ba22; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_refunds
    ADD CONSTRAINT fk_rails_a02352ba22 FOREIGN KEY (payment_id) REFERENCES public.recording_studio_billing_payments(id);

-- Name: recording_studio_billing_usage_ledger_entries fk_rails_a09cef4e82; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_ledger_entries
    ADD CONSTRAINT fk_rails_a09cef4e82 FOREIGN KEY (usage_period_id) REFERENCES public.recording_studio_billing_usage_periods(id);

-- Name: recording_studio_billing_usage_ledger_entries fk_rails_a381620ba7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_ledger_entries
    ADD CONSTRAINT fk_rails_a381620ba7 FOREIGN KEY (usage_credit_grant_id) REFERENCES public.recording_studio_billing_usage_credit_grants(id);

-- Name: recording_studio_billing_financial_adjustments fk_rails_a42c5114ef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_adjustments
    ADD CONSTRAINT fk_rails_a42c5114ef FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_webhook_effects fk_rails_aa052199d4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_webhook_effects
    ADD CONSTRAINT fk_rails_aa052199d4 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_refund_intents fk_rails_ac859b998f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_refund_intents
    ADD CONSTRAINT fk_rails_ac859b998f FOREIGN KEY (payment_id) REFERENCES public.recording_studio_billing_payments(id);

-- Name: recording_studio_billing_rated_usage_settlements fk_rails_ae4a8877f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usage_settlements
    ADD CONSTRAINT fk_rails_ae4a8877f1 FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_ledger_entries fk_rails_af410220df; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_ledger_entries
    ADD CONSTRAINT fk_rails_af410220df FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_refund_intents fk_rails_afb61f61d3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_refund_intents
    ADD CONSTRAINT fk_rails_afb61f61d3 FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_corrections fk_rails_b0e3bd3478; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_corrections
    ADD CONSTRAINT fk_rails_b0e3bd3478 FOREIGN KEY (tax_calculation_id) REFERENCES public.recording_studio_billing_tax_calculations(id);

-- Name: recording_studio_billing_usage_events fk_rails_b6561d39f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_events
    ADD CONSTRAINT fk_rails_b6561d39f1 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_meter_aggregations fk_rails_b715e0782f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_meter_aggregations
    ADD CONSTRAINT fk_rails_b715e0782f FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_allocations fk_rails_ba2cb2b15e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_allocations
    ADD CONSTRAINT fk_rails_ba2cb2b15e FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_checkout_intents fk_rails_bab17f442c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intents
    ADD CONSTRAINT fk_rails_bab17f442c FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_allocations fk_rails_bae485b4a6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_allocations
    ADD CONSTRAINT fk_rails_bae485b4a6 FOREIGN KEY (usage_period_id) REFERENCES public.recording_studio_billing_usage_periods(id);

-- Name: recording_studio_billing_rated_usages fk_rails_bcb788189f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usages
    ADD CONSTRAINT fk_rails_bcb788189f FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_overage_prices fk_rails_bd104db33e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_prices
    ADD CONSTRAINT fk_rails_bd104db33e FOREIGN KEY (market_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_periods fk_rails_bdd2fa4687; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_periods
    ADD CONSTRAINT fk_rails_bdd2fa4687 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_financial_adjustments fk_rails_be02a5b3e8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_adjustments
    ADD CONSTRAINT fk_rails_be02a5b3e8 FOREIGN KEY (adjustment_intent_id) REFERENCES public.recording_studio_billing_adjustment_intents(id);

-- Name: recording_studio_billing_financial_commands fk_rails_beae460789; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_commands
    ADD CONSTRAINT fk_rails_beae460789 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_subscription_change_intents fk_rails_bf36b26762; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_change_intents
    ADD CONSTRAINT fk_rails_bf36b26762 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_credit_allocations fk_rails_c2ee643ad3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_credit_allocations
    ADD CONSTRAINT fk_rails_c2ee643ad3 FOREIGN KEY (usage_credit_grant_id) REFERENCES public.recording_studio_billing_usage_credit_grants(id);

-- Name: recording_studio_billing_feature_overrides fk_rails_c386383455; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_feature_overrides
    ADD CONSTRAINT fk_rails_c386383455 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_tax_calculations fk_rails_c41f9eb26c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT fk_rails_c41f9eb26c FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_credit_ledger_entries fk_rails_c4e2d771c3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_credit_ledger_entries
    ADD CONSTRAINT fk_rails_c4e2d771c3 FOREIGN KEY (purchase_effect_id) REFERENCES public.recording_studio_billing_purchase_effects(id);

-- Name: recording_studio_billing_rated_usage_settlements fk_rails_c69d309478; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usage_settlements
    ADD CONSTRAINT fk_rails_c69d309478 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_rate_cards fk_rails_ca9368a435; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rate_cards
    ADD CONSTRAINT fk_rails_ca9368a435 FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_rated_usage_settlements fk_rails_cb2aba86cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usage_settlements
    ADD CONSTRAINT fk_rails_cb2aba86cf FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_adjustment_intents fk_rails_d17cedc866; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_adjustment_intents
    ADD CONSTRAINT fk_rails_d17cedc866 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_subscription_change_intents fk_rails_d1fad01faf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_change_intents
    ADD CONSTRAINT fk_rails_d1fad01faf FOREIGN KEY (subscription_id) REFERENCES public.recording_studio_billing_subscriptions(id);

-- Name: recording_studio_billing_tax_calculations fk_rails_d5913910b5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT fk_rails_d5913910b5 FOREIGN KEY (supersedes_id) REFERENCES public.recording_studio_billing_tax_calculations(id);

-- Name: recording_studio_billing_usage_corrections fk_rails_d6d888a54c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_corrections
    ADD CONSTRAINT fk_rails_d6d888a54c FOREIGN KEY (usage_allocation_id) REFERENCES public.recording_studio_billing_usage_allocations(id);

-- Name: recording_studio_billing_product_rules fk_rails_d8f5b1928a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_product_rules
    ADD CONSTRAINT fk_rails_d8f5b1928a FOREIGN KEY (target_product_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_overage_calculations fk_rails_d9d5104528; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_calculations
    ADD CONSTRAINT fk_rails_d9d5104528 FOREIGN KEY (usage_allocation_id) REFERENCES public.recording_studio_billing_usage_allocations(id);

-- Name: recording_studio_billing_payments fk_rails_da854b1259; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_payments
    ADD CONSTRAINT fk_rails_da854b1259 FOREIGN KEY (invoice_id) REFERENCES public.recording_studio_billing_invoices(id);

-- Name: recording_studio_billing_rated_usage_settlements fk_rails_db4b276e0c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rated_usage_settlements
    ADD CONSTRAINT fk_rails_db4b276e0c FOREIGN KEY (usage_period_id) REFERENCES public.recording_studio_billing_usage_periods(id);

-- Name: recording_studio_billing_checkout_attempts fk_rails_de6ed4bdf2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_attempts
    ADD CONSTRAINT fk_rails_de6ed4bdf2 FOREIGN KEY (financial_command_attempt_id) REFERENCES public.recording_studio_billing_financial_command_attempts(id);

-- Name: recording_studio_billing_usage_allocations fk_rails_dea52d5f40; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_allocations
    ADD CONSTRAINT fk_rails_dea52d5f40 FOREIGN KEY (rated_usage_id) REFERENCES public.recording_studio_billing_rated_usages(id);

-- Name: recording_studio_billing_reconciliation_records fk_rails_deb283311f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_reconciliation_records
    ADD CONSTRAINT fk_rails_deb283311f FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_usage_allowance_policies fk_rails_defb070ea5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_allowance_policies
    ADD CONSTRAINT fk_rails_defb070ea5 FOREIGN KEY (usage_period_id) REFERENCES public.recording_studio_billing_usage_periods(id);

-- Name: recording_studio_billing_checkout_attempts fk_rails_e0ac93ff05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_attempts
    ADD CONSTRAINT fk_rails_e0ac93ff05 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_plan_update_runs fk_rails_e1efe7faa6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_update_runs
    ADD CONSTRAINT fk_rails_e1efe7faa6 FOREIGN KEY (plan_update_id) REFERENCES public.recording_studio_billing_plan_updates(id);

-- Name: recording_studio_billing_subscription_change_intents fk_rails_e454961746; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_change_intents
    ADD CONSTRAINT fk_rails_e454961746 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_checkout_attempts fk_rails_e66059dc8f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_attempts
    ADD CONSTRAINT fk_rails_e66059dc8f FOREIGN KEY (checkout_intent_id) REFERENCES public.recording_studio_billing_checkout_intents(id);

-- Name: recording_studio_billing_markets fk_rails_e81c1eaa3f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_markets
    ADD CONSTRAINT fk_rails_e81c1eaa3f FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_cost_rates fk_rails_e9f02ab3e1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_rates
    ADD CONSTRAINT fk_rails_e9f02ab3e1 FOREIGN KEY (usage_unit_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_refund_intents fk_rails_eaf5f904f2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_refund_intents
    ADD CONSTRAINT fk_rails_eaf5f904f2 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_meter_aggregations fk_rails_eb540df9eb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_meter_aggregations
    ADD CONSTRAINT fk_rails_eb540df9eb FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_subscriptions fk_rails_eb5461aa73; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscriptions
    ADD CONSTRAINT fk_rails_eb5461aa73 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_subscription_items fk_rails_f23081330d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_items
    ADD CONSTRAINT fk_rails_f23081330d FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_products fk_rails_f2d073142d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_products
    ADD CONSTRAINT fk_rails_f2d073142d FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_reconciliation_issues fk_rails_f34d73b261; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_reconciliation_issues
    ADD CONSTRAINT fk_rails_f34d73b261 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);

-- Name: recording_studio_billing_webhook_effects fk_rails_f5cb15010c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_webhook_effects
    ADD CONSTRAINT fk_rails_f5cb15010c FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_ledger_entries fk_rails_f6ca7a76f4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_ledger_entries
    ADD CONSTRAINT fk_rails_f6ca7a76f4 FOREIGN KEY (usage_allocation_id) REFERENCES public.recording_studio_billing_usage_allocations(id);

-- Name: recording_studio_billing_usage_ledger_entries fk_rails_f8cee7b253; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_ledger_entries
    ADD CONSTRAINT fk_rails_f8cee7b253 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_plan_update_applications fk_rails_fad5e84a01; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_update_applications
    ADD CONSTRAINT fk_rails_fad5e84a01 FOREIGN KEY (plan_update_id) REFERENCES public.recording_studio_billing_plan_updates(id);

-- Name: recording_studio_billing_provider_references fk_rails_fdca126298; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_provider_references
    ADD CONSTRAINT fk_rails_fdca126298 FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_usage_units fk_rails_ff6cd411aa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_usage_units
    ADD CONSTRAINT fk_rails_ff6cd411aa FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_commercial_publication_candidates fk_rs_billing_candidates_root; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_commercial_publication_candidates
    ADD CONSTRAINT fk_rs_billing_candidates_root FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

-- Name: recording_studio_billing_commercial_manifests fk_rs_billing_manifests_root; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_commercial_manifests
    ADD CONSTRAINT fk_rs_billing_manifests_root FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);

SET search_path TO "$user", public;
