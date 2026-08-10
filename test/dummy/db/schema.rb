# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_10_000003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "admin_roots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_admin_roots_on_name", unique: true
  end

  create_table "recording_studio_billing_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.uuid "root_recording_id", null: false
    t.datetime "updated_at", null: false
    t.index ["root_recording_id"], name: "index_recording_studio_billing_accounts_on_root_recording_id", unique: true
  end

  create_table "recording_studio_billing_billing_admins", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.uuid "root_recording_id", null: false
    t.datetime "updated_at", null: false
    t.index ["root_recording_id"], name: "idx_on_root_recording_id_b72e653703", unique: true
  end

  create_table "recording_studio_billing_billing_options", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "kind", null: false
    t.uuid "product_recording_id", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["product_recording_id"], name: "idx_on_product_recording_id_387e136700"
    t.check_constraint "kind::text = ANY (ARRAY['recurring'::character varying, 'usage'::character varying]::text[])", name: "rs_billing_options_kind"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_billing_options_state"
  end

  create_table "recording_studio_billing_cost_cards", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.uuid "provider_account_recording_id", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_account_recording_id"], name: "idx_on_provider_account_recording_id_de683655d9"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_cost_cards_state"
  end

  create_table "recording_studio_billing_cost_rates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "amount_minor", null: false
    t.uuid "cost_card_recording_id", null: false
    t.datetime "created_at", null: false
    t.string "currency_code", null: false
    t.integer "currency_exponent", null: false
    t.string "key", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.uuid "usage_unit_recording_id", null: false
    t.index ["cost_card_recording_id"], name: "idx_on_cost_card_recording_id_f59059cf73"
    t.index ["usage_unit_recording_id"], name: "idx_on_usage_unit_recording_id_676a199a57"
    t.check_constraint "amount_minor >= 0", name: "recording_studio_billing_cost_rates_amount_minor"
    t.check_constraint "currency_code::text ~ '^[A-Z]{3}$'::text", name: "recording_studio_billing_cost_rates_currency_code"
    t.check_constraint "currency_exponent >= 0 AND currency_exponent <= 3", name: "recording_studio_billing_cost_rates_currency_exponent"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_cost_rates_state"
  end

  create_table "recording_studio_billing_feature_overrides", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_recording_id", null: false
    t.datetime "created_at", null: false
    t.uuid "feature_recording_id", null: false
    t.string "key", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.jsonb "value", default: {}, null: false
    t.index ["account_recording_id"], name: "idx_on_account_recording_id_bf46d23ae6"
    t.index ["feature_recording_id"], name: "idx_on_feature_recording_id_6dcf40615b"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_feature_overrides_state"
  end

  create_table "recording_studio_billing_features", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "kind", null: false
    t.uuid "product_recording_id", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["product_recording_id"], name: "idx_on_product_recording_id_b3abe2c34c"
    t.check_constraint "kind::text = ANY (ARRAY['boolean'::character varying, 'quantity'::character varying]::text[])", name: "rs_billing_features_kind"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_features_state"
  end

  create_table "recording_studio_billing_markets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "country_code", null: false
    t.datetime "created_at", null: false
    t.string "currency_code", null: false
    t.string "key", null: false
    t.uuid "provider_account_recording_id", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_account_recording_id"], name: "idx_on_provider_account_recording_id_917bf5f52e"
    t.check_constraint "country_code::text ~ '^[A-Z]{2}$'::text", name: "recording_studio_billing_markets_country_code"
    t.check_constraint "currency_code::text ~ '^[A-Z]{3}$'::text", name: "recording_studio_billing_markets_currency_code"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_markets_state"
  end

  create_table "recording_studio_billing_meters", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "aggregation", null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.uuid "usage_unit_recording_id", null: false
    t.index ["usage_unit_recording_id"], name: "idx_on_usage_unit_recording_id_20bbb0eead"
    t.check_constraint "aggregation::text = ANY (ARRAY['sum'::character varying, 'count'::character varying, 'last_value'::character varying]::text[])", name: "rs_billing_meters_aggregation"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_meters_state"
  end

  create_table "recording_studio_billing_overage_prices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "amount_minor", null: false
    t.uuid "billing_option_recording_id", null: false
    t.datetime "created_at", null: false
    t.string "currency_code", null: false
    t.integer "currency_exponent", null: false
    t.string "key", null: false
    t.uuid "market_recording_id", null: false
    t.integer "package_size"
    t.string "pricing_model", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.uuid "usage_unit_recording_id", null: false
    t.integer "version", null: false
    t.index ["billing_option_recording_id", "market_recording_id", "usage_unit_recording_id", "currency_code", "version"], name: "idx_rs_billing_active_overage_prices", unique: true, where: "((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying])::text[]))"
    t.index ["billing_option_recording_id"], name: "idx_on_billing_option_recording_id_4b4b3a8dfa"
    t.index ["market_recording_id"], name: "idx_on_market_recording_id_2ba99ee38f"
    t.index ["usage_unit_recording_id"], name: "idx_on_usage_unit_recording_id_9e76a066d4"
    t.check_constraint "amount_minor >= 0", name: "recording_studio_billing_overage_prices_amount_minor"
    t.check_constraint "currency_code::text ~ '^[A-Z]{3}$'::text", name: "recording_studio_billing_overage_prices_currency_code"
    t.check_constraint "currency_exponent >= 0 AND currency_exponent <= 3", name: "recording_studio_billing_overage_prices_currency_exponent"
    t.check_constraint "pricing_model::text = 'package'::text AND package_size IS NOT NULL AND package_size > 0 OR (pricing_model::text = ANY (ARRAY['flat'::character varying, 'per_unit'::character varying]::text[])) AND package_size IS NULL", name: "recording_studio_billing_overage_prices_package_size"
    t.check_constraint "pricing_model::text = ANY (ARRAY['flat'::character varying, 'per_unit'::character varying, 'package'::character varying]::text[])", name: "recording_studio_billing_overage_prices_pricing_model"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_overage_prices_state"
    t.check_constraint "version >= 1", name: "recording_studio_billing_overage_prices_version"
  end

  create_table "recording_studio_billing_plan_updates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "billing_option_recording_id", null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["billing_option_recording_id"], name: "idx_on_billing_option_recording_id_df8562f2e7"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_plan_updates_state"
  end

  create_table "recording_studio_billing_prices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "amount_minor", null: false
    t.uuid "billing_option_recording_id", null: false
    t.datetime "created_at", null: false
    t.string "currency_code", null: false
    t.integer "currency_exponent", null: false
    t.string "key", null: false
    t.uuid "market_recording_id", null: false
    t.integer "package_size"
    t.string "pricing_model", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["billing_option_recording_id", "market_recording_id", "currency_code", "version"], name: "idx_rs_billing_active_prices", unique: true, where: "((state)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying])::text[]))"
    t.index ["billing_option_recording_id"], name: "idx_on_billing_option_recording_id_f4dd8ca6e3"
    t.index ["market_recording_id"], name: "index_recording_studio_billing_prices_on_market_recording_id"
    t.check_constraint "amount_minor >= 0", name: "recording_studio_billing_prices_amount_minor"
    t.check_constraint "currency_code::text ~ '^[A-Z]{3}$'::text", name: "recording_studio_billing_prices_currency_code"
    t.check_constraint "currency_exponent >= 0 AND currency_exponent <= 3", name: "recording_studio_billing_prices_currency_exponent"
    t.check_constraint "pricing_model::text = 'package'::text AND package_size IS NOT NULL AND package_size > 0 OR (pricing_model::text = ANY (ARRAY['flat'::character varying, 'per_unit'::character varying]::text[])) AND package_size IS NULL", name: "recording_studio_billing_prices_package_size"
    t.check_constraint "pricing_model::text = ANY (ARRAY['flat'::character varying, 'per_unit'::character varying, 'package'::character varying]::text[])", name: "recording_studio_billing_prices_pricing_model"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_prices_state"
    t.check_constraint "version >= 1", name: "recording_studio_billing_prices_version"
  end

  create_table "recording_studio_billing_product_rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.uuid "product_recording_id", null: false
    t.string "rule_type", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["product_recording_id"], name: "idx_on_product_recording_id_cca2c7df22"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_product_rules_state"
  end

  create_table "recording_studio_billing_products", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "kind", null: false
    t.uuid "provider_account_recording_id", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_account_recording_id"], name: "idx_on_provider_account_recording_id_75eb593078"
    t.check_constraint "kind::text = ANY (ARRAY['subscription'::character varying, 'one_time'::character varying]::text[])", name: "rs_billing_products_kind"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_products_state"
  end

  create_table "recording_studio_billing_provider_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "billing_admin_recording_id", null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "provider", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["billing_admin_recording_id"], name: "idx_on_billing_admin_recording_id_e9c004ac4f"
    t.check_constraint "provider::text ~ '^[a-z][a-z0-9_]*$'::text", name: "rs_billing_provider_accounts_provider_format"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_provider_accounts_state"
  end

  create_table "recording_studio_billing_rate_cards", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.uuid "provider_account_recording_id", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_account_recording_id"], name: "idx_on_provider_account_recording_id_829622d336"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_rate_cards_state"
  end

  create_table "recording_studio_billing_rates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "amount_minor", null: false
    t.datetime "created_at", null: false
    t.string "currency_code", null: false
    t.integer "currency_exponent", null: false
    t.string "key", null: false
    t.uuid "rate_card_recording_id", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.uuid "usage_unit_recording_id", null: false
    t.index ["rate_card_recording_id"], name: "index_recording_studio_billing_rates_on_rate_card_recording_id"
    t.index ["usage_unit_recording_id"], name: "idx_on_usage_unit_recording_id_737a9cb844"
    t.check_constraint "amount_minor >= 0", name: "recording_studio_billing_rates_amount_minor"
    t.check_constraint "currency_code::text ~ '^[A-Z]{3}$'::text", name: "recording_studio_billing_rates_currency_code"
    t.check_constraint "currency_exponent >= 0 AND currency_exponent <= 3", name: "recording_studio_billing_rates_currency_exponent"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_rates_state"
  end

  create_table "recording_studio_billing_usage_units", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.uuid "provider_account_recording_id", null: false
    t.string "state", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_account_recording_id"], name: "idx_on_provider_account_recording_id_d0aeb02284"
    t.check_constraint "state::text = ANY (ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying]::text[])", name: "recording_studio_billing_usage_units_state"
  end

  create_table "recording_studio_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id"
    t.string "actor_type"
    t.datetime "created_at", null: false
    t.string "idempotency_key"
    t.uuid "impersonator_id"
    t.string "impersonator_type"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.uuid "previous_recordable_id"
    t.string "previous_recordable_type"
    t.uuid "recordable_id", null: false
    t.string "recordable_type", null: false
    t.uuid "recording_id", null: false
    t.index ["recording_id", "idempotency_key"], name: "index_recording_studio_events_on_recording_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["recording_id"], name: "index_recording_studio_events_on_recording_id"
  end

  create_table "recording_studio_recordings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "parent_recording_id"
    t.uuid "recordable_id", null: false
    t.string "recordable_type", null: false
    t.uuid "root_recording_id"
    t.datetime "trashed_at"
    t.datetime "updated_at", null: false
    t.index ["parent_recording_id"], name: "index_recording_studio_recordings_on_parent_recording_id"
    t.index ["recordable_type", "recordable_id", "parent_recording_id", "trashed_at"], name: "index_recording_studio_recordings_on_recordable_parent_trashed"
    t.index ["recordable_type", "recordable_id"], name: "index_recording_studio_recordings_on_recordable"
    t.index ["root_recording_id"], name: "index_rs_recordings_on_root_recording"
  end

  create_table "recording_studio_root_switchable_selections", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "actor_id"
    t.string "actor_type"
    t.datetime "created_at", null: false
    t.string "device_browser"
    t.string "device_key", null: false
    t.string "device_label"
    t.string "device_platform"
    t.string "device_type"
    t.datetime "last_used_at", null: false
    t.uuid "root_recording_id", null: false
    t.string "scope_key", null: false
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.index ["actor_type", "actor_id", "device_key", "scope_key"], name: "idx_rs_root_switchable_actor_device_scope", unique: true, where: "(actor_id IS NOT NULL)"
    t.index ["device_key", "scope_key"], name: "idx_rs_root_switchable_anonymous_device_scope", unique: true, where: "(actor_id IS NULL)"
    t.index ["root_recording_id"], name: "idx_rs_root_switchable_root_recording"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "workspaces", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "recording_studio_billing_accounts", "recording_studio_recordings", column: "root_recording_id"
  add_foreign_key "recording_studio_billing_billing_admins", "recording_studio_recordings", column: "root_recording_id"
  add_foreign_key "recording_studio_billing_billing_options", "recording_studio_recordings", column: "product_recording_id"
  add_foreign_key "recording_studio_billing_cost_cards", "recording_studio_recordings", column: "provider_account_recording_id"
  add_foreign_key "recording_studio_billing_cost_rates", "recording_studio_recordings", column: "cost_card_recording_id"
  add_foreign_key "recording_studio_billing_cost_rates", "recording_studio_recordings", column: "usage_unit_recording_id"
  add_foreign_key "recording_studio_billing_feature_overrides", "recording_studio_recordings", column: "account_recording_id"
  add_foreign_key "recording_studio_billing_feature_overrides", "recording_studio_recordings", column: "feature_recording_id"
  add_foreign_key "recording_studio_billing_features", "recording_studio_recordings", column: "product_recording_id"
  add_foreign_key "recording_studio_billing_markets", "recording_studio_recordings", column: "provider_account_recording_id"
  add_foreign_key "recording_studio_billing_meters", "recording_studio_recordings", column: "usage_unit_recording_id"
  add_foreign_key "recording_studio_billing_overage_prices", "recording_studio_recordings", column: "billing_option_recording_id"
  add_foreign_key "recording_studio_billing_overage_prices", "recording_studio_recordings", column: "market_recording_id"
  add_foreign_key "recording_studio_billing_overage_prices", "recording_studio_recordings", column: "usage_unit_recording_id"
  add_foreign_key "recording_studio_billing_plan_updates", "recording_studio_recordings", column: "billing_option_recording_id"
  add_foreign_key "recording_studio_billing_prices", "recording_studio_recordings", column: "billing_option_recording_id"
  add_foreign_key "recording_studio_billing_prices", "recording_studio_recordings", column: "market_recording_id"
  add_foreign_key "recording_studio_billing_product_rules", "recording_studio_recordings", column: "product_recording_id"
  add_foreign_key "recording_studio_billing_products", "recording_studio_recordings", column: "provider_account_recording_id"
  add_foreign_key "recording_studio_billing_provider_accounts", "recording_studio_recordings", column: "billing_admin_recording_id"
  add_foreign_key "recording_studio_billing_rate_cards", "recording_studio_recordings", column: "provider_account_recording_id"
  add_foreign_key "recording_studio_billing_rates", "recording_studio_recordings", column: "rate_card_recording_id"
  add_foreign_key "recording_studio_billing_rates", "recording_studio_recordings", column: "usage_unit_recording_id"
  add_foreign_key "recording_studio_billing_usage_units", "recording_studio_recordings", column: "provider_account_recording_id"
  add_foreign_key "recording_studio_events", "recording_studio_recordings", column: "recording_id"
  add_foreign_key "recording_studio_recordings", "recording_studio_recordings", column: "parent_recording_id"
  add_foreign_key "recording_studio_recordings", "recording_studio_recordings", column: "root_recording_id"
end
