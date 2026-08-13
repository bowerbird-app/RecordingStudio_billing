# frozen_string_literal: true

class ScopeProviderWebhookReceipts < ActiveRecord::Migration[8.1]
  def change
    # Clean-install policy: receipt-scoped columns and indexes are created atomically.
  end
end
