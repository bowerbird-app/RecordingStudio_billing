# frozen_string_literal: true

require "gem_template/version"
require "gem_template/engine"
require "gem_template/configuration"
require "gem_template/services/base_service"
require "gem_template/services/example_service"

module GemTemplate
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
    end
  end
end
