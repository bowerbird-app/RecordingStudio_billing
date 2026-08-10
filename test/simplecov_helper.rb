# frozen_string_literal: true

return if ENV["DISABLE_SIMPLECOV"] == "true"

begin
  require "simplecov"
rescue LoadError
  return
end

SimpleCov.start do
  enable_coverage :branch
  add_filter "/test/"
  add_filter "/config/"
  add_filter "/db/"
end
