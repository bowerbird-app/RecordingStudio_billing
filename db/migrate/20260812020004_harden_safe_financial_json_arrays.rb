# frozen_string_literal: true

class HardenSafeFinancialJsonArrays < ActiveRecord::Migration[8.1]
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
              FROM jsonb_each(nodes.value) entry
              WHERE jsonb_typeof(nodes.value) = 'object'
              UNION ALL
              SELECT NULL::text, element.value
              FROM jsonb_array_elements(nodes.value) element
              WHERE jsonb_typeof(nodes.value) = 'array'
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
    raise ActiveRecord::IrreversibleMigration
  end
end
