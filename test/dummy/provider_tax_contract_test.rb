# frozen_string_literal: true

ENV.delete("DATABASE_URL")
ENV["DB_NAME"] = "app_test"

require File.expand_path("../provider_tax_contract_test", __dir__)
