# frozen_string_literal: true

class HardenCommercialPublications < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_studio_billing_commercial_publication_candidates, :snapshot_envelope, :jsonb,
               null: false, default: {}
    add_index :recording_studio_billing_commercial_publication_candidates,
              %i[root_recording_id effective_at], unique: true,
                                                  name: "rs_billing_publication_candidate_identity"
    conversion_present = "NOT (conversion_numerator IS NULL AND conversion_denominator IS NULL " \
                         "AND conversion_decimal IS NULL)"
    add_check_constraint :recording_studio_billing_rates,
                         conversion_present,
                         name: "rs_billing_rates_conversion_present"
  end

  def down
    remove_check_constraint :recording_studio_billing_rates, name: "rs_billing_rates_conversion_present"
    remove_index :recording_studio_billing_commercial_publication_candidates,
                 name: "rs_billing_publication_candidate_identity"
    remove_column :recording_studio_billing_commercial_publication_candidates, :snapshot_envelope
  end
end
