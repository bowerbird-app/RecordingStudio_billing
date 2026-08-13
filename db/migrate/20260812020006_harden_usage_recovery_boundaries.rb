# frozen_string_literal: true

class HardenUsageRecoveryBoundaries < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION rs_billing_safe_financial_json(payload jsonb) RETURNS boolean AS $$
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
      $$ LANGUAGE plpgsql IMMUTABLE;
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS rs_billing_safe_financial_json(jsonb)"
  end
end
