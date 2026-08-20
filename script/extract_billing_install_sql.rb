# frozen_string_literal: true

# One-shot helper: extract the current billing DDL from the dummy structure dump
# and emit a clean-install SQL file with V1 vocabulary already applied.
require "pathname"

root = Pathname.new(File.expand_path("..", __dir__))
structure = root.join("test/dummy/db/structure.sql").read
output = root.join("db/schema/install_recording_studio_billing.sql")

objects = structure.split("\n--\n-- Name: ")
kept = []

objects.each_with_index do |object, index|
  body = index.zero? ? object : "-- Name: #{object}"
  next unless body.match?(/recording_studio_billing_|rs_billing_/)

  body = body.split("\n--\n-- PostgreSQL database dump complete").first
  next if body.match?(/\A(?:--|SET |SELECT pg_catalog|INSERT INTO "schema_migrations"|INSERT INTO "ar_internal_metadata")/)
  next if body.match?(/CREATE TABLE public\.(schema_migrations|ar_internal_metadata)/)

  kept << body.strip
end

sql = kept.join("\n\n")
sql = sql.gsub(
  "scope character varying DEFAULT 'default'::character varying NOT NULL",
  "scope character varying DEFAULT 'market'::character varying NOT NULL"
)
sql = sql.gsub(
  /CONSTRAINT recording_studio_billing_(prices|overage_prices)_v1_scope CHECK \(\(\(scope\)::text = 'default'::text\)\)/,
  "CONSTRAINT recording_studio_billing_\\1_v1_scope CHECK (((scope)::text = 'market'::text))"
)
sql = sql.gsub(
  "CONSTRAINT rs_billing_options_tax_policy CHECK (((tax_policy)::text = ANY (ARRAY[('exclusive'::character varying)::text, ('inclusive'::character varying)::text, ('automatic'::character varying)::text])))",
  "CONSTRAINT rs_billing_options_tax_policy CHECK (((tax_policy)::text = ANY (ARRAY[('exclusive'::character varying)::text, ('inclusive'::character varying)::text, ('provider_default'::character varying)::text])))"
)
sql = sql.gsub(
  "CONSTRAINT rs_billing_options_collection_method CHECK (((collection_method)::text = ANY (ARRAY[('automatic'::character varying)::text, ('invoice'::character varying)::text])))",
  "CONSTRAINT rs_billing_options_collection_method CHECK (((collection_method)::text = ANY (ARRAY[('automatic'::character varying)::text, ('send_invoice'::character varying)::text])))"
)
sql = sql.gsub(
  "AND ((collection_method)::text = ANY (ARRAY[('automatic'::character varying)::text, ('invoice'::character varying)::text])) AND",
  "AND ((collection_method)::text = ANY (ARRAY[('automatic'::character varying)::text, ('send_invoice'::character varying)::text])) AND"
)

output.dirname.mkpath
header = <<~SQL
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
SQL
footer = <<~SQL
  SET search_path TO "$user", public;
SQL
output.write("#{header}\n#{sql}\n#{footer}")
warn "Wrote #{output} (#{sql.bytesize} bytes, #{kept.size} objects)"
