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
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS '';


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


--
-- Name: rs_billing_protect_checkout_item(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_checkout_item() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION 'checkout intent items are immutable'; END;
$$;


--
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


--
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


--
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


--
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


--
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


--
-- Name: rs_billing_protect_subscription_item_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_subscription_item_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE expected_version integer;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'subscription item versions are append-only'; END IF;
  IF TG_OP = 'INSERT' THEN
    IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_subscriptions subscription JOIN recording_studio_billing_checkout_intents intent ON intent.id = NEW.checkout_intent_id JOIN recording_studio_billing_checkout_intent_items item ON item.id = NEW.checkout_intent_item_id WHERE subscription.id = NEW.subscription_id AND subscription.root_recording_id = NEW.root_recording_id AND subscription.account_recording_id = NEW.account_recording_id AND intent.root_recording_id = NEW.root_recording_id AND intent.account_recording_id = NEW.account_recording_id AND item.checkout_intent_id = intent.id AND item.manifest_digest = NEW.manifest_digest AND EXISTS (SELECT 1 FROM recording_studio_billing_commercial_manifests manifest WHERE manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL)) THEN RAISE EXCEPTION 'subscription item version source authority is invalid'; END IF;
    IF NEW.line_key <> (CASE WHEN NEW.mode = 'recurring_addon' THEN NEW.product_recording_id::text || ':' || NEW.billing_option_recording_id::text ELSE NEW.product_recording_id::text END) THEN RAISE EXCEPTION 'subscription item version line identity is invalid'; END IF;
    SELECT COALESCE(MAX(version_number), 0) + 1 INTO expected_version FROM recording_studio_billing_subscription_item_versions WHERE subscription_id = NEW.subscription_id AND line_key = NEW.line_key;
    IF NEW.version_number IS DISTINCT FROM expected_version THEN RAISE EXCEPTION 'subscription item versions must be sequential'; END IF;
    IF NOT rs_billing_safe_financial_json(NEW.commercial_snapshot) THEN RAISE EXCEPTION 'subscription item version contains unsafe data'; END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(OLD) - 'effective_ends_at' - 'superseded_at' - 'updated_at') IS DISTINCT FROM (to_jsonb(NEW) - 'effective_ends_at' - 'superseded_at' - 'updated_at') OR OLD.effective_ends_at IS NOT NULL OR NEW.effective_ends_at IS NULL THEN RAISE EXCEPTION 'subscription item version history is immutable'; END IF;
  RETURN NEW;
END;
$$;


--
-- Name: rs_billing_protect_tax_calculation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_protect_tax_calculation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'tax calculations are immutable and append-only';
END;
$$;


--
-- Name: rs_billing_safe_financial_json(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_safe_financial_json(payload jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $_$
  SELECT NOT EXISTS (
    SELECT 1
    FROM jsonb_path_query(payload, '$.** ? (@.type() == "object")') AS object(value)
    CROSS JOIN LATERAL jsonb_object_keys(object.value) AS key(name)
    WHERE key.name ~* '(authorization|credential|password|secret|token|api[_-]?key|private[_-]?key|signature|card[_-]?(number|cvc|cvv)|payment[_-]?(nonce|credential)|bank[_-]?account|routing[_-]?number|provider[_-]?(url|uri|id|identifier|account[_-]?id|customer[_-]?id|response|payload|body)|raw[_-]?(provider|response|payload|body)|(^|[_-])(tax|vat)[_-]?(id|identifier|number)|(^|[_-])(email|phone|address|postal[_-]?code|ip[_-]?address)|(^|[_-])(url|uri))$'
  ) AND NOT jsonb_path_exists(
    payload,
    '$.** ? (@.type() == "string" && @ like_regex "^[[:space:]]*(https?|ftp)://" flag "i")'
  );
$_$;


--
-- Name: rs_billing_subscription_lifecycle(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_subscription_lifecycle() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'subscriptions are durable'; END IF;
  IF OLD.root_recording_id IS DISTINCT FROM NEW.root_recording_id OR OLD.account_recording_id IS DISTINCT FROM NEW.account_recording_id OR OLD.identifier IS DISTINCT FROM NEW.identifier OR OLD.provider_reference IS DISTINCT FROM NEW.provider_reference THEN RAISE EXCEPTION 'subscription authority is immutable'; END IF;
  IF NOT ((OLD.state = 'trialing' AND NEW.state IN ('active', 'paused', 'cancelled', 'expired')) OR (OLD.state = 'active' AND NEW.state IN ('past_due', 'paused', 'cancelled', 'expired')) OR (OLD.state = 'past_due' AND NEW.state IN ('active', 'paused', 'cancelled', 'expired')) OR (OLD.state = 'paused' AND NEW.state IN ('active', 'cancelled', 'expired')) OR OLD.state = NEW.state) THEN RAISE EXCEPTION 'subscription lifecycle transition is invalid'; END IF;
  RETURN NEW;
END;
$$;


--
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


--
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


--
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


--
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


--
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


--
-- Name: rs_billing_validate_command_authority(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_command_authority() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT rs_billing_safe_financial_json(NEW.canonical_request -> 'request')
     OR NOT rs_billing_safe_financial_json(NEW.normalized_result)
     OR NOT rs_billing_safe_financial_json(NEW.safe_error_details)
     OR NEW.provider_reference ~* '^[[:space:]]*(https?|ftp)://' THEN
    RAISE EXCEPTION 'financial command contains unsafe persisted data';
  END IF;
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
  RETURN NEW;
END;
$$;


--
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


--
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


--
-- Name: rs_billing_validate_tax_authority(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rs_billing_validate_tax_authority() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE command_request jsonb;
DECLARE command_result jsonb;
DECLARE command_metadata jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM recording_studio_recordings root
    WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL
      AND root.root_recording_id = root.id AND root.trashed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'tax root authority is invalid';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM recording_studio_recordings account_recording
    JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
    WHERE account_recording.id = NEW.account_recording_id
      AND account_recording.recordable_type = 'RecordingStudioBilling::Account'
      AND account_recording.root_recording_id = NEW.root_recording_id
      AND account_recording.parent_recording_id = NEW.root_recording_id
      AND account_recording.trashed_at IS NULL AND account.root_recording_id = NEW.root_recording_id
  ) THEN
    RAISE EXCEPTION 'tax account authority is invalid';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM recording_studio_billing_commercial_manifests manifest
    WHERE manifest.id = NEW.commercial_manifest_id AND manifest.root_recording_id = NEW.root_recording_id
      AND manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'tax manifest authority is invalid';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM recording_studio_billing_financial_commands command
    WHERE command.id = NEW.financial_command_id AND command.command_type = 'tax_calculation'
      AND command.root_recording_id = NEW.root_recording_id
      AND command.account_recording_id = NEW.account_recording_id
      AND command.calculator_key = NEW.calculator_key
      AND command.calculator_mode = NEW.calculator_mode
  ) THEN
    RAISE EXCEPTION 'tax command authority is invalid';
  END IF;
  SELECT canonical_request -> 'request', normalized_result
    INTO command_request, command_result
  FROM recording_studio_billing_financial_commands WHERE id = NEW.financial_command_id;
  SELECT safe_metadata INTO command_metadata
  FROM recording_studio_billing_financial_command_attempts
  WHERE financial_command_id = NEW.financial_command_id AND completed_at IS NOT NULL
  ORDER BY attempt_number DESC LIMIT 1;
  IF command_request ->> 'commercial_manifest_id' IS DISTINCT FROM NEW.commercial_manifest_id::text
     OR command_request ->> 'commercial_manifest_digest' IS DISTINCT FROM NEW.manifest_digest
     OR command_request ->> 'transaction_type' IS DISTINCT FROM NEW.transaction_type
     OR command_request ->> 'operation_reference' IS DISTINCT FROM NEW.operation_reference
     OR command_request ->> 'idempotency_key' IS DISTINCT FROM NEW.idempotency_key
     OR (command_request ->> 'subtotal_minor')::bigint IS DISTINCT FROM NEW.subtotal_minor
     OR (command_request ->> 'discount_minor')::bigint IS DISTINCT FROM NEW.discount_minor
     OR command_request ->> 'currency' IS DISTINCT FROM NEW.currency
     OR command_result ->> 'request_fingerprint' IS DISTINCT FROM NEW.request_fingerprint
     OR command_result ->> 'status' IS DISTINCT FROM NEW.status
     OR (command_result ->> 'subtotal_minor')::bigint IS DISTINCT FROM NEW.subtotal_minor
     OR (command_result ->> 'discount_minor')::bigint IS DISTINCT FROM NEW.discount_minor
     OR (command_result ->> 'tax_minor')::bigint IS DISTINCT FROM NEW.tax_minor
     OR (command_result ->> 'total_minor')::bigint IS DISTINCT FROM NEW.total_minor
     OR command_result ->> 'currency' IS DISTINCT FROM NEW.currency
      OR command_result ->> 'behavior' IS DISTINCT FROM NEW.behavior
      OR command_result -> 'breakdown' IS DISTINCT FROM NEW.breakdown
      OR command_result ->> 'calculator_reference' IS DISTINCT FROM NEW.calculator_reference
      OR (command_result ->> 'calculated_at')::timestamptz IS DISTINCT FROM NEW.calculated_at
      OR command_metadata IS DISTINCT FROM NEW.safe_metadata THEN
    RAISE EXCEPTION 'tax calculation does not match its durable command';
  END IF;
    IF NOT rs_billing_safe_financial_json(NEW.breakdown)
      OR NOT rs_billing_safe_financial_json(NEW.safe_metadata)
      OR NEW.operation_reference ~* '^[[:space:]]*(https?|ftp)://'
      OR NEW.calculator_reference ~* '^[[:space:]]*(https?|ftp)://' THEN
     RAISE EXCEPTION 'tax calculation contains unsafe persisted data';
    END IF;
  IF NEW.revision_number > 1 AND NOT EXISTS (
    SELECT 1 FROM recording_studio_billing_tax_calculations previous
    WHERE previous.id = NEW.supersedes_id
      AND previous.financial_command_id = NEW.financial_command_id
      AND previous.revision_number = NEW.revision_number - 1
      AND previous.root_recording_id = NEW.root_recording_id
      AND previous.idempotency_key = NEW.idempotency_key
      AND previous.calculator_key = NEW.calculator_key
      AND previous.calculator_mode = NEW.calculator_mode
      AND previous.request_fingerprint = NEW.request_fingerprint
  ) THEN
    RAISE EXCEPTION 'tax calculation revision history is invalid';
  END IF;
  RETURN NEW;
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
    CONSTRAINT recording_studio_billing_billing_options_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_options_checkout_policy CHECK (((checkout_policy)::text = ANY (ARRAY[('allowed'::character varying)::text, ('required'::character varying)::text, ('disabled'::character varying)::text]))),
    CONSTRAINT rs_billing_options_collection_method CHECK (((collection_method)::text = ANY (ARRAY[('automatic'::character varying)::text, ('invoice'::character varying)::text]))),
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
    CONSTRAINT rs_billing_options_tax_policy CHECK (((tax_policy)::text = ANY (ARRAY[('exclusive'::character varying)::text, ('inclusive'::character varying)::text, ('automatic'::character varying)::text]))),
    CONSTRAINT rs_billing_options_trial_days CHECK ((trial_days >= 0))
);


--
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


--
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


--
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
    CONSTRAINT recording_studio_billing_cost_cards_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
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
    CONSTRAINT recording_studio_billing_cost_rates_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
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
    CONSTRAINT recording_studio_billing_feature_overrides_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
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
    CONSTRAINT recording_studio_billing_features_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_features_kind CHECK (((kind)::text = ANY (ARRAY[('boolean'::character varying)::text, ('limit'::character varying)::text, ('allowance'::character varying)::text, ('variant'::character varying)::text])))
);


--
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


--
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
    CONSTRAINT recording_studio_billing_markets_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
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
    CONSTRAINT recording_studio_billing_meters_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_meters_aggregation CHECK (((aggregation)::text = ANY (ARRAY[('sum'::character varying)::text, ('count'::character varying)::text, ('maximum'::character varying)::text, ('latest'::character varying)::text])))
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
    CONSTRAINT recording_studio_billing_overage_prices_package_size CHECK (((((pricing_model)::text = 'package'::text) AND (package_size IS NOT NULL) AND (package_size > 0)) OR (((pricing_model)::text = ANY (ARRAY[('flat'::character varying)::text, ('per_unit'::character varying)::text])) AND (package_size IS NULL)))),
    CONSTRAINT recording_studio_billing_overage_prices_pricing_model CHECK (((pricing_model)::text = ANY (ARRAY[('flat'::character varying)::text, ('per_unit'::character varying)::text, ('package'::character varying)::text]))),
    CONSTRAINT recording_studio_billing_overage_prices_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
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
    CONSTRAINT recording_studio_billing_plan_updates_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
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
    CONSTRAINT recording_studio_billing_prices_package_size CHECK (((((pricing_model)::text = 'package'::text) AND (package_size IS NOT NULL) AND (package_size > 0)) OR (((pricing_model)::text = ANY (ARRAY[('flat'::character varying)::text, ('per_unit'::character varying)::text])) AND (package_size IS NULL)))),
    CONSTRAINT recording_studio_billing_prices_pricing_model CHECK (((pricing_model)::text = ANY (ARRAY[('flat'::character varying)::text, ('per_unit'::character varying)::text, ('package'::character varying)::text]))),
    CONSTRAINT recording_studio_billing_prices_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
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
    CONSTRAINT recording_studio_billing_product_rules_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
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
    CONSTRAINT recording_studio_billing_products_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_products_kind CHECK (((kind)::text = ANY (ARRAY[('plan'::character varying)::text, ('addon'::character varying)::text, ('credit_pack'::character varying)::text, ('service'::character varying)::text])))
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
    CONSTRAINT recording_studio_billing_provider_accounts_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_provider_accounts_provider_format CHECK (((adapter_key)::text ~ '^[a-z][a-z0-9_]*$'::text))
);


--
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
    CONSTRAINT rs_billing_purchase_effect_kind CHECK (((effect_kind)::text = ANY ((ARRAY['one_off_addon'::character varying, 'credit_pack'::character varying])::text[]))),
    CONSTRAINT rs_billing_purchase_effect_metadata_object CHECK ((jsonb_typeof(safe_metadata) = 'object'::text))
);


--
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
    CONSTRAINT rs_billing_purchase_modes CHECK (((mode)::text = ANY ((ARRAY['one_off_addon'::character varying, 'one_off_credit_pack'::character varying])::text[]))),
    CONSTRAINT rs_billing_purchase_snapshot_object CHECK ((jsonb_typeof(commercial_snapshot) = 'object'::text))
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
    CONSTRAINT recording_studio_billing_rate_cards_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
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
    CONSTRAINT recording_studio_billing_rates_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT rs_billing_rates_conversion CHECK ((((conversion_numerator IS NOT NULL) AND (conversion_numerator > 0) AND (conversion_denominator IS NOT NULL) AND (conversion_denominator > 0) AND (conversion_decimal IS NULL)) OR ((conversion_numerator IS NULL) AND (conversion_denominator IS NULL) AND (conversion_decimal IS NOT NULL) AND (conversion_decimal > (0)::numeric)))),
    CONSTRAINT rs_billing_rates_conversion_present CHECK ((NOT ((conversion_numerator IS NULL) AND (conversion_denominator IS NULL) AND (conversion_decimal IS NULL))))
);


--
-- Name: recording_studio_billing_subscription_item_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_studio_billing_subscription_item_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    root_recording_id uuid NOT NULL,
    account_recording_id uuid NOT NULL,
    checkout_intent_id uuid NOT NULL,
    checkout_intent_item_id uuid NOT NULL,
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
    CONSTRAINT rs_billing_subscription_item_amount_quantity CHECK (((amount_minor >= 0) AND (quantity > 0))),
    CONSTRAINT rs_billing_subscription_item_currency CHECK (((currency_code)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT rs_billing_subscription_item_dates CHECK (((effective_ends_at IS NULL) OR (effective_ends_at >= effective_starts_at))),
    CONSTRAINT rs_billing_subscription_item_digest CHECK (((manifest_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT rs_billing_subscription_item_line_key CHECK (((line_key)::text ~ '^[0-9a-f-]{36}(:[0-9a-f-]{36})?$'::text)),
    CONSTRAINT rs_billing_subscription_item_modes CHECK (((mode)::text = ANY ((ARRAY['free_plan'::character varying, 'monthly_subscription'::character varying, 'annual_subscription'::character varying, 'trial_subscription'::character varying, 'recurring_addon'::character varying])::text[]))),
    CONSTRAINT rs_billing_subscription_item_snapshot_object CHECK ((jsonb_typeof(commercial_snapshot) = 'object'::text))
);


--
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
    CONSTRAINT rs_billing_subscriptions_state CHECK (((state)::text = ANY ((ARRAY['trialing'::character varying, 'active'::character varying, 'past_due'::character varying, 'paused'::character varying, 'cancelled'::character varying, 'expired'::character varying])::text[])))
);


--
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
    CONSTRAINT rs_billing_tax_arithmetic CHECK (((((behavior)::text = 'exclusive'::text) AND (total_minor = ((subtotal_minor - discount_minor) + tax_minor))) OR (((behavior)::text = ANY (ARRAY[('inclusive'::character varying)::text, ('provider_default'::character varying)::text])) AND (total_minor = (subtotal_minor - discount_minor)) AND (tax_minor <= total_minor)))),
    CONSTRAINT rs_billing_tax_behavior CHECK (((behavior)::text = ANY (ARRAY[('inclusive'::character varying)::text, ('exclusive'::character varying)::text, ('provider_default'::character varying)::text]))),
    CONSTRAINT rs_billing_tax_calculator_key CHECK (((calculator_key)::text ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT rs_billing_tax_calculator_mode CHECK (((calculator_mode)::text = ANY (ARRAY[('external_calculation'::character varying)::text, ('provider_calculation'::character varying)::text]))),
    CONSTRAINT rs_billing_tax_currency CHECK (((currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT rs_billing_tax_digests CHECK ((((manifest_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT rs_billing_tax_discount CHECK ((discount_minor <= subtotal_minor)),
    CONSTRAINT rs_billing_tax_nonnegative CHECK (((subtotal_minor >= 0) AND (discount_minor >= 0) AND (tax_minor >= 0) AND (total_minor >= 0))),
    CONSTRAINT rs_billing_tax_revision CHECK (((revision_number > 0) AND ((revision_number = 1) = (supersedes_id IS NULL)))),
    CONSTRAINT rs_billing_tax_safe_json CHECK (((jsonb_typeof(breakdown) = 'array'::text) AND (jsonb_typeof(safe_metadata) = 'object'::text))),
    CONSTRAINT rs_billing_tax_status CHECK (((status)::text = ANY (ARRAY[('success'::character varying)::text, ('duplicate'::character varying)::text, ('invalid'::character varying)::text, ('unauthorized'::character varying)::text, ('unsupported'::character varying)::text, ('unsupported_tax_calculation'::character varying)::text, ('unsupported_checkout_mode'::character varying)::text, ('unsupported_checkout_composition'::character varying)::text, ('unsupported_subscription_composition'::character varying)::text, ('unsupported_market'::character varying)::text, ('unsupported_currency'::character varying)::text, ('charge_market_verification_unavailable'::character varying)::text, ('conflict'::character varying)::text, ('provider_unavailable'::character varying)::text, ('provider_rejected'::character varying)::text, ('pending'::character varying)::text, ('stale'::character varying)::text, ('rate_missing'::character varying)::text, ('rate_ambiguous'::character varying)::text, ('requires_review'::character varying)::text, ('failed'::character varying)::text, ('unknown'::character varying)::text])))
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
    CONSTRAINT recording_studio_billing_usage_units_state CHECK (((state)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
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
-- Name: recording_studio_billing_checkout_attempts recording_studio_billing_checkout_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_attempts
    ADD CONSTRAINT recording_studio_billing_checkout_attempts_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_checkout_intent_items recording_studio_billing_checkout_intent_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intent_items
    ADD CONSTRAINT recording_studio_billing_checkout_intent_items_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_checkout_intents recording_studio_billing_checkout_intents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intents
    ADD CONSTRAINT recording_studio_billing_checkout_intents_pkey PRIMARY KEY (id);


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
-- Name: recording_studio_billing_financial_command_attempts recording_studio_billing_financial_command_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_command_attempts
    ADD CONSTRAINT recording_studio_billing_financial_command_attempts_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_financial_commands recording_studio_billing_financial_commands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_commands
    ADD CONSTRAINT recording_studio_billing_financial_commands_pkey PRIMARY KEY (id);


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
-- Name: recording_studio_billing_purchase_effects recording_studio_billing_purchase_effects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchase_effects
    ADD CONSTRAINT recording_studio_billing_purchase_effects_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_purchases recording_studio_billing_purchases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchases
    ADD CONSTRAINT recording_studio_billing_purchases_pkey PRIMARY KEY (id);


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
-- Name: recording_studio_billing_subscription_item_versions recording_studio_billing_subscription_item_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT recording_studio_billing_subscription_item_versions_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_subscriptions recording_studio_billing_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscriptions
    ADD CONSTRAINT recording_studio_billing_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: recording_studio_billing_tax_calculations recording_studio_billing_tax_calculations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT recording_studio_billing_tax_calculations_pkey PRIMARY KEY (id);


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
-- Name: idx_on_account_recording_id_40b0a22061; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_40b0a22061 ON public.recording_studio_billing_subscription_item_versions USING btree (account_recording_id);


--
-- Name: idx_on_account_recording_id_513c128e1f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_513c128e1f ON public.recording_studio_billing_subscriptions USING btree (account_recording_id);


--
-- Name: idx_on_account_recording_id_530b2ad4ba; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_530b2ad4ba ON public.recording_studio_billing_purchases USING btree (account_recording_id);


--
-- Name: idx_on_account_recording_id_60eab6e700; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_60eab6e700 ON public.recording_studio_billing_purchase_effects USING btree (account_recording_id);


--
-- Name: idx_on_account_recording_id_8e401e15ba; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_8e401e15ba ON public.recording_studio_billing_checkout_intents USING btree (account_recording_id);


--
-- Name: idx_on_account_recording_id_937d9dc223; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_937d9dc223 ON public.recording_studio_billing_financial_commands USING btree (account_recording_id);


--
-- Name: idx_on_account_recording_id_bf46d23ae6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_bf46d23ae6 ON public.recording_studio_billing_feature_overrides USING btree (account_recording_id);


--
-- Name: idx_on_account_recording_id_cd6cb724a1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_recording_id_cd6cb724a1 ON public.recording_studio_billing_tax_calculations USING btree (account_recording_id);


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
-- Name: idx_on_checkout_intent_id_3bbe25d7ff; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_checkout_intent_id_3bbe25d7ff ON public.recording_studio_billing_checkout_intent_items USING btree (checkout_intent_id);


--
-- Name: idx_on_checkout_intent_id_3c0ba4cf49; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_checkout_intent_id_3c0ba4cf49 ON public.recording_studio_billing_checkout_attempts USING btree (checkout_intent_id);


--
-- Name: idx_on_checkout_intent_id_60a7fdca1d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_checkout_intent_id_60a7fdca1d ON public.recording_studio_billing_subscription_item_versions USING btree (checkout_intent_id);


--
-- Name: idx_on_commercial_manifest_id_c6e0df96a7; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_commercial_manifest_id_c6e0df96a7 ON public.recording_studio_billing_tax_calculations USING btree (commercial_manifest_id);


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
-- Name: idx_on_financial_command_attempt_id_0ab43bb24a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_attempt_id_0ab43bb24a ON public.recording_studio_billing_checkout_attempts USING btree (financial_command_attempt_id);


--
-- Name: idx_on_financial_command_id_144b6e8c5b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_144b6e8c5b ON public.recording_studio_billing_checkout_intents USING btree (financial_command_id);


--
-- Name: idx_on_financial_command_id_6b7f641e35; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_6b7f641e35 ON public.recording_studio_billing_checkout_attempts USING btree (financial_command_id);


--
-- Name: idx_on_financial_command_id_81fdfb0193; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_81fdfb0193 ON public.recording_studio_billing_financial_command_attempts USING btree (financial_command_id);


--
-- Name: idx_on_financial_command_id_df93af6f81; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_financial_command_id_df93af6f81 ON public.recording_studio_billing_tax_calculations USING btree (financial_command_id);


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
-- Name: idx_on_provider_account_recording_id_e7e6d6a62d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_account_recording_id_e7e6d6a62d ON public.recording_studio_billing_financial_commands USING btree (provider_account_recording_id);


--
-- Name: idx_on_root_recording_id_107421795e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_107421795e ON public.recording_studio_billing_subscription_item_versions USING btree (root_recording_id);


--
-- Name: idx_on_root_recording_id_52395a8cdb; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_52395a8cdb ON public.recording_studio_billing_subscriptions USING btree (root_recording_id);


--
-- Name: idx_on_root_recording_id_c1ebf50973; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_c1ebf50973 ON public.recording_studio_billing_financial_commands USING btree (root_recording_id);


--
-- Name: idx_on_root_recording_id_c9449b0ded; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_c9449b0ded ON public.recording_studio_billing_tax_calculations USING btree (root_recording_id);


--
-- Name: idx_on_root_recording_id_d63849b28a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_d63849b28a ON public.recording_studio_billing_commercial_manifests USING btree (root_recording_id);


--
-- Name: idx_on_root_recording_id_e8f7404b06; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_e8f7404b06 ON public.recording_studio_billing_purchase_effects USING btree (root_recording_id);


--
-- Name: idx_on_root_recording_id_f7b40e9183; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_root_recording_id_f7b40e9183 ON public.recording_studio_billing_checkout_intents USING btree (root_recording_id);


--
-- Name: idx_on_subscription_id_eca2627d32; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_subscription_id_eca2627d32 ON public.recording_studio_billing_subscription_item_versions USING btree (subscription_id);


--
-- Name: idx_on_supersedes_id_d934e98c73; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_supersedes_id_d934e98c73 ON public.recording_studio_billing_tax_calculations USING btree (supersedes_id);


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
-- Name: idx_rs_billing_checkout_attempt_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_checkout_attempt_number ON public.recording_studio_billing_checkout_attempts USING btree (checkout_intent_id, attempt_number);


--
-- Name: idx_rs_billing_checkout_intent_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_checkout_intent_idempotency ON public.recording_studio_billing_checkout_intents USING btree (root_recording_id, local_idempotency_key);


--
-- Name: idx_rs_billing_checkout_items_option; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_checkout_items_option ON public.recording_studio_billing_checkout_intent_items USING btree (checkout_intent_id, billing_option_recording_id);


--
-- Name: idx_rs_billing_command_attempt_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_command_attempt_number ON public.recording_studio_billing_financial_command_attempts USING btree (financial_command_id, attempt_number);


--
-- Name: idx_rs_billing_commands_local_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_commands_local_idempotency ON public.recording_studio_billing_financial_commands USING btree (root_recording_id, local_idempotency_key);


--
-- Name: idx_rs_billing_commands_operation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_commands_operation ON public.recording_studio_billing_financial_commands USING btree (operation_id);


--
-- Name: idx_rs_billing_commands_pending_work; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_commands_pending_work ON public.recording_studio_billing_financial_commands USING btree (created_at) WHERE ((state)::text = 'pending'::text);


--
-- Name: idx_rs_billing_commands_provider_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_commands_provider_idempotency ON public.recording_studio_billing_financial_commands USING btree (provider_idempotency_key);


--
-- Name: idx_rs_billing_commands_reconciliation_work; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_commands_reconciliation_work ON public.recording_studio_billing_financial_commands USING btree (updated_at) WHERE (((state)::text = 'requires_reconciliation'::text) OR ((reconciliation_state)::text = 'pending'::text));


--
-- Name: idx_rs_billing_commands_stale_processing; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_commands_stale_processing ON public.recording_studio_billing_financial_commands USING btree (lease_expires_at) WHERE ((state)::text = 'processing'::text);


--
-- Name: idx_rs_billing_one_account_per_root; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_one_account_per_root ON public.recording_studio_recordings USING btree (root_recording_id) WHERE ((recordable_type)::text = 'RecordingStudioBilling::Account'::text);


--
-- Name: idx_rs_billing_one_admin_per_root; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_one_admin_per_root ON public.recording_studio_recordings USING btree (root_recording_id) WHERE ((recordable_type)::text = 'RecordingStudioBilling::BillingAdmin'::text);


--
-- Name: idx_rs_billing_one_processing_attempt; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_one_processing_attempt ON public.recording_studio_billing_financial_command_attempts USING btree (financial_command_id) WHERE (((state)::text = 'processing'::text) AND (completed_at IS NULL));


--
-- Name: idx_rs_billing_purchase_checkout_item; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_purchase_checkout_item ON public.recording_studio_billing_purchases USING btree (checkout_intent_item_id);


--
-- Name: idx_rs_billing_purchase_effect_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_purchase_effect_idempotency ON public.recording_studio_billing_purchase_effects USING btree (root_recording_id, idempotency_key);


--
-- Name: idx_rs_billing_subscription_account; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscription_account ON public.recording_studio_billing_subscriptions USING btree (root_recording_id, account_recording_id);


--
-- Name: idx_rs_billing_subscription_item_checkout_item; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscription_item_checkout_item ON public.recording_studio_billing_subscription_item_versions USING btree (checkout_intent_item_id);


--
-- Name: idx_rs_billing_subscription_item_line_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscription_item_line_version ON public.recording_studio_billing_subscription_item_versions USING btree (subscription_id, line_key, version_number);


--
-- Name: idx_rs_billing_subscriptions_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_subscriptions_identifier ON public.recording_studio_billing_subscriptions USING btree (identifier);


--
-- Name: idx_rs_billing_tax_command_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_tax_command_revision ON public.recording_studio_billing_tax_calculations USING btree (financial_command_id, revision_number);


--
-- Name: idx_rs_billing_tax_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rs_billing_tax_fingerprint ON public.recording_studio_billing_tax_calculations USING btree (request_fingerprint);


--
-- Name: idx_rs_billing_tax_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rs_billing_tax_idempotency ON public.recording_studio_billing_tax_calculations USING btree (root_recording_id, idempotency_key, revision_number);


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
-- Name: index_recording_studio_billing_purchase_effects_on_purchase_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_purchase_effects_on_purchase_id ON public.recording_studio_billing_purchase_effects USING btree (purchase_id);


--
-- Name: index_recording_studio_billing_purchases_on_checkout_intent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_purchases_on_checkout_intent_id ON public.recording_studio_billing_purchases USING btree (checkout_intent_id);


--
-- Name: index_recording_studio_billing_purchases_on_root_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_studio_billing_purchases_on_root_recording_id ON public.recording_studio_billing_purchases USING btree (root_recording_id);


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

CREATE TRIGGER recording_studio_billing_billing_options_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_billing_options FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::BillingOption');


--
-- Name: recording_studio_billing_billing_options recording_studio_billing_billing_options_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_billing_options_validate_publication AFTER INSERT ON public.recording_studio_billing_billing_options DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::BillingOption');


--
-- Name: recording_studio_billing_cost_cards recording_studio_billing_cost_cards_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_cost_cards_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_cost_cards FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::CostCard');


--
-- Name: recording_studio_billing_cost_cards recording_studio_billing_cost_cards_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_cost_cards_validate_publication AFTER INSERT ON public.recording_studio_billing_cost_cards DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::CostCard');


--
-- Name: recording_studio_billing_cost_rates recording_studio_billing_cost_rates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_cost_rates_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_cost_rates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::CostRate');


--
-- Name: recording_studio_billing_cost_rates recording_studio_billing_cost_rates_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_cost_rates_validate_publication AFTER INSERT ON public.recording_studio_billing_cost_rates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::CostRate');


--
-- Name: recording_studio_billing_feature_overrides recording_studio_billing_feature_overrides_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_feature_overrides_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_feature_overrides FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::FeatureOverride');


--
-- Name: recording_studio_billing_feature_overrides recording_studio_billing_feature_overrides_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_feature_overrides_validate_publication AFTER INSERT ON public.recording_studio_billing_feature_overrides DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::FeatureOverride');


--
-- Name: recording_studio_billing_features recording_studio_billing_features_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_features_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_features FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Feature');


--
-- Name: recording_studio_billing_features recording_studio_billing_features_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_features_validate_publication AFTER INSERT ON public.recording_studio_billing_features DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Feature');


--
-- Name: recording_studio_billing_markets recording_studio_billing_markets_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_markets_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_markets FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Market');


--
-- Name: recording_studio_billing_markets recording_studio_billing_markets_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_markets_validate_publication AFTER INSERT ON public.recording_studio_billing_markets DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Market');


--
-- Name: recording_studio_billing_meters recording_studio_billing_meters_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_meters_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_meters FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Meter');


--
-- Name: recording_studio_billing_meters recording_studio_billing_meters_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_meters_validate_publication AFTER INSERT ON public.recording_studio_billing_meters DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Meter');


--
-- Name: recording_studio_billing_overage_prices recording_studio_billing_overage_prices_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_overage_prices_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_overage_prices FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::OveragePrice');


--
-- Name: recording_studio_billing_overage_prices recording_studio_billing_overage_prices_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_overage_prices_validate_publication AFTER INSERT ON public.recording_studio_billing_overage_prices DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::OveragePrice');


--
-- Name: recording_studio_billing_plan_updates recording_studio_billing_plan_updates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_plan_updates_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_plan_updates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::PlanUpdate');


--
-- Name: recording_studio_billing_plan_updates recording_studio_billing_plan_updates_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_plan_updates_validate_publication AFTER INSERT ON public.recording_studio_billing_plan_updates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::PlanUpdate');


--
-- Name: recording_studio_billing_prices recording_studio_billing_prices_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_prices_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_prices FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Price');


--
-- Name: recording_studio_billing_prices recording_studio_billing_prices_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_prices_validate_publication AFTER INSERT ON public.recording_studio_billing_prices DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Price');


--
-- Name: recording_studio_billing_product_rules recording_studio_billing_product_rules_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_product_rules_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_product_rules FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::ProductRule');


--
-- Name: recording_studio_billing_product_rules recording_studio_billing_product_rules_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_product_rules_validate_publication AFTER INSERT ON public.recording_studio_billing_product_rules DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::ProductRule');


--
-- Name: recording_studio_billing_products recording_studio_billing_products_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_products_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_products FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Product');


--
-- Name: recording_studio_billing_products recording_studio_billing_products_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_products_validate_publication AFTER INSERT ON public.recording_studio_billing_products DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Product');


--
-- Name: recording_studio_billing_provider_accounts recording_studio_billing_provider_accounts_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_provider_accounts_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_provider_accounts FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::ProviderAccount');


--
-- Name: recording_studio_billing_provider_accounts recording_studio_billing_provider_accounts_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_provider_accounts_validate_publication AFTER INSERT ON public.recording_studio_billing_provider_accounts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::ProviderAccount');


--
-- Name: recording_studio_billing_rate_cards recording_studio_billing_rate_cards_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_rate_cards_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_rate_cards FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::RateCard');


--
-- Name: recording_studio_billing_rate_cards recording_studio_billing_rate_cards_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_rate_cards_validate_publication AFTER INSERT ON public.recording_studio_billing_rate_cards DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::RateCard');


--
-- Name: recording_studio_billing_rates recording_studio_billing_rates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_rates_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_rates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::Rate');


--
-- Name: recording_studio_billing_rates recording_studio_billing_rates_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_rates_validate_publication AFTER INSERT ON public.recording_studio_billing_rates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::Rate');


--
-- Name: recording_studio_billing_usage_units recording_studio_billing_usage_units_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_studio_billing_usage_units_protect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_usage_units FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_commercial_history('RecordingStudioBilling::UsageUnit');


--
-- Name: recording_studio_billing_usage_units recording_studio_billing_usage_units_validate_publication; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER recording_studio_billing_usage_units_validate_publication AFTER INSERT ON public.recording_studio_billing_usage_units DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_commercial_publication('RecordingStudioBilling::UsageUnit');


--
-- Name: recording_studio_billing_commercial_publication_candidates rs_billing_candidates_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_candidates_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_commercial_publication_candidates FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_candidate_history();


--
-- Name: recording_studio_billing_checkout_attempts rs_billing_checkout_attempt_command_correlation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_attempt_command_correlation BEFORE INSERT OR UPDATE OF financial_command_attempt_id ON public.recording_studio_billing_checkout_attempts FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_checkout_attempt_command_correlation();


--
-- Name: recording_studio_billing_checkout_attempts rs_billing_checkout_attempt_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_attempt_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_checkout_attempts FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_checkout_attempt();


--
-- Name: recording_studio_billing_checkout_intents rs_billing_checkout_intent_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_intent_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_checkout_intents FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_checkout_authority();


--
-- Name: recording_studio_billing_checkout_intents rs_billing_checkout_intent_command_binding; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_intent_command_binding BEFORE UPDATE OF financial_command_id ON public.recording_studio_billing_checkout_intents FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_checkout_command_binding();


--
-- Name: recording_studio_billing_checkout_intents rs_billing_checkout_intent_execution_state; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_intent_execution_state BEFORE UPDATE OF state ON public.recording_studio_billing_checkout_intents FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_checkout_execution_state();


--
-- Name: recording_studio_billing_checkout_intent_items rs_billing_checkout_item_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_checkout_item_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_checkout_intent_items FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_checkout_item();


--
-- Name: recording_studio_billing_financial_command_attempts rs_billing_command_attempt_consistency_from_attempt; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER rs_billing_command_attempt_consistency_from_attempt AFTER INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_financial_command_attempts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_command_attempt_consistency();


--
-- Name: recording_studio_billing_financial_commands rs_billing_command_attempt_consistency_from_command; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER rs_billing_command_attempt_consistency_from_command AFTER INSERT OR UPDATE ON public.recording_studio_billing_financial_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_command_attempt_consistency();


--
-- Name: recording_studio_billing_financial_command_attempts rs_billing_command_attempt_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_command_attempt_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_financial_command_attempts FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_command_attempt();


--
-- Name: recording_studio_billing_financial_commands rs_billing_financial_command_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_financial_command_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_financial_commands FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_command_authority();


--
-- Name: recording_studio_billing_financial_commands rs_billing_financial_command_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_financial_command_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_financial_commands FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_financial_command();


--
-- Name: recording_studio_billing_commercial_manifests rs_billing_manifests_protect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_manifests_protect_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_commercial_manifests FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_manifest_history();


--
-- Name: recording_studio_billing_purchases rs_billing_purchase_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_purchase_authority BEFORE INSERT ON public.recording_studio_billing_purchases FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_lifecycle_projection();


--
-- Name: recording_studio_billing_purchase_effects rs_billing_purchase_effect_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_purchase_effect_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_purchase_effects FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_purchase_effect();


--
-- Name: recording_studio_billing_purchases rs_billing_purchase_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_purchase_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_purchases FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_purchase();


--
-- Name: recording_studio_billing_subscriptions rs_billing_subscription_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_subscription_authority BEFORE INSERT OR UPDATE ON public.recording_studio_billing_subscriptions FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_lifecycle_projection();


--
-- Name: recording_studio_billing_subscription_item_versions rs_billing_subscription_item_version_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_subscription_item_version_history BEFORE INSERT OR DELETE OR UPDATE ON public.recording_studio_billing_subscription_item_versions FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_subscription_item_version();


--
-- Name: recording_studio_billing_subscriptions rs_billing_subscription_lifecycle; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_subscription_lifecycle BEFORE DELETE OR UPDATE ON public.recording_studio_billing_subscriptions FOR EACH ROW EXECUTE FUNCTION public.rs_billing_subscription_lifecycle();


--
-- Name: recording_studio_billing_tax_calculations rs_billing_tax_calculation_authority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_tax_calculation_authority BEFORE INSERT ON public.recording_studio_billing_tax_calculations FOR EACH ROW EXECUTE FUNCTION public.rs_billing_validate_tax_authority();


--
-- Name: recording_studio_billing_tax_calculations rs_billing_tax_calculation_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rs_billing_tax_calculation_history BEFORE DELETE OR UPDATE ON public.recording_studio_billing_tax_calculations FOR EACH ROW EXECUTE FUNCTION public.rs_billing_protect_tax_calculation();


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
-- Name: recording_studio_billing_purchases fk_rails_2db0688675; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchases
    ADD CONSTRAINT fk_rails_2db0688675 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_checkout_intents fk_rails_2ec9aa65bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intents
    ADD CONSTRAINT fk_rails_2ec9aa65bd FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);


--
-- Name: recording_studio_billing_tax_calculations fk_rails_31eed02146; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT fk_rails_31eed02146 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);


--
-- Name: recording_studio_billing_billing_options fk_rails_33726a97d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_billing_options
    ADD CONSTRAINT fk_rails_33726a97d6 FOREIGN KEY (product_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_purchase_effects fk_rails_3e3b69f431; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchase_effects
    ADD CONSTRAINT fk_rails_3e3b69f431 FOREIGN KEY (purchase_id) REFERENCES public.recording_studio_billing_purchases(id);


--
-- Name: recording_studio_billing_purchases fk_rails_436859f7d5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchases
    ADD CONSTRAINT fk_rails_436859f7d5 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_checkout_intent_items fk_rails_454ae16426; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intent_items
    ADD CONSTRAINT fk_rails_454ae16426 FOREIGN KEY (checkout_intent_id) REFERENCES public.recording_studio_billing_checkout_intents(id);


--
-- Name: recording_studio_billing_financial_commands fk_rails_45f2293813; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_commands
    ADD CONSTRAINT fk_rails_45f2293813 FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_purchase_effects fk_rails_481999b1e3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchase_effects
    ADD CONSTRAINT fk_rails_481999b1e3 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_subscription_item_versions fk_rails_4992812ca8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT fk_rails_4992812ca8 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_purchase_effects fk_rails_4b371c645a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchase_effects
    ADD CONSTRAINT fk_rails_4b371c645a FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_plan_updates fk_rails_511ec0e839; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_plan_updates
    ADD CONSTRAINT fk_rails_511ec0e839 FOREIGN KEY (billing_option_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_tax_calculations fk_rails_580f212427; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT fk_rails_580f212427 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_subscription_item_versions fk_rails_59234eacda; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT fk_rails_59234eacda FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_financial_commands fk_rails_5a6dd935b1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_commands
    ADD CONSTRAINT fk_rails_5a6dd935b1 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


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
-- Name: recording_studio_billing_subscription_item_versions fk_rails_77212d5465; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT fk_rails_77212d5465 FOREIGN KEY (subscription_id) REFERENCES public.recording_studio_billing_subscriptions(id);


--
-- Name: recording_studio_billing_subscription_item_versions fk_rails_7ad7f1b975; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscription_item_versions
    ADD CONSTRAINT fk_rails_7ad7f1b975 FOREIGN KEY (checkout_intent_id) REFERENCES public.recording_studio_billing_checkout_intents(id);


--
-- Name: recording_studio_billing_purchases fk_rails_7f6c19f3a5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_purchases
    ADD CONSTRAINT fk_rails_7f6c19f3a5 FOREIGN KEY (checkout_intent_id) REFERENCES public.recording_studio_billing_checkout_intents(id);


--
-- Name: recording_studio_billing_cost_cards fk_rails_7fe81ededc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_cost_cards
    ADD CONSTRAINT fk_rails_7fe81ededc FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_financial_command_attempts fk_rails_87375cc605; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_command_attempts
    ADD CONSTRAINT fk_rails_87375cc605 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);


--
-- Name: recording_studio_billing_tax_calculations fk_rails_896fceb34d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT fk_rails_896fceb34d FOREIGN KEY (commercial_manifest_id) REFERENCES public.recording_studio_billing_commercial_manifests(id);


--
-- Name: recording_studio_billing_overage_prices fk_rails_9546dcb8cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_prices
    ADD CONSTRAINT fk_rails_9546dcb8cf FOREIGN KEY (billing_option_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_subscriptions fk_rails_97d9baa876; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscriptions
    ADD CONSTRAINT fk_rails_97d9baa876 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_checkout_intents fk_rails_9ad6795b60; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intents
    ADD CONSTRAINT fk_rails_9ad6795b60 FOREIGN KEY (root_recording_id) REFERENCES public.recording_studio_recordings(id);


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
-- Name: recording_studio_billing_checkout_intents fk_rails_bab17f442c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_intents
    ADD CONSTRAINT fk_rails_bab17f442c FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_overage_prices fk_rails_bd104db33e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_overage_prices
    ADD CONSTRAINT fk_rails_bd104db33e FOREIGN KEY (market_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_financial_commands fk_rails_beae460789; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_financial_commands
    ADD CONSTRAINT fk_rails_beae460789 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_feature_overrides fk_rails_c386383455; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_feature_overrides
    ADD CONSTRAINT fk_rails_c386383455 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_tax_calculations fk_rails_c41f9eb26c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT fk_rails_c41f9eb26c FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_rate_cards fk_rails_ca9368a435; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_rate_cards
    ADD CONSTRAINT fk_rails_ca9368a435 FOREIGN KEY (provider_account_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_tax_calculations fk_rails_d5913910b5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_tax_calculations
    ADD CONSTRAINT fk_rails_d5913910b5 FOREIGN KEY (supersedes_id) REFERENCES public.recording_studio_billing_tax_calculations(id);


--
-- Name: recording_studio_billing_product_rules fk_rails_d8f5b1928a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_product_rules
    ADD CONSTRAINT fk_rails_d8f5b1928a FOREIGN KEY (target_product_recording_id) REFERENCES public.recording_studio_recordings(id);


--
-- Name: recording_studio_billing_checkout_attempts fk_rails_de6ed4bdf2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_attempts
    ADD CONSTRAINT fk_rails_de6ed4bdf2 FOREIGN KEY (financial_command_attempt_id) REFERENCES public.recording_studio_billing_financial_command_attempts(id);


--
-- Name: recording_studio_billing_checkout_attempts fk_rails_e0ac93ff05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_attempts
    ADD CONSTRAINT fk_rails_e0ac93ff05 FOREIGN KEY (financial_command_id) REFERENCES public.recording_studio_billing_financial_commands(id);


--
-- Name: recording_studio_billing_checkout_attempts fk_rails_e66059dc8f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_checkout_attempts
    ADD CONSTRAINT fk_rails_e66059dc8f FOREIGN KEY (checkout_intent_id) REFERENCES public.recording_studio_billing_checkout_intents(id);


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
-- Name: recording_studio_billing_subscriptions fk_rails_eb5461aa73; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_studio_billing_subscriptions
    ADD CONSTRAINT fk_rails_eb5461aa73 FOREIGN KEY (account_recording_id) REFERENCES public.recording_studio_recordings(id);


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

