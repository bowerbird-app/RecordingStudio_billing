# frozen_string_literal: true

require_relative "lib/recording_studio_billing/version"

Gem::Specification.new do |spec|
  spec.name        = "recording_studio_billing"
  spec.version     = RecordingStudioBilling::VERSION
  spec.authors     = ["Bowerbird"]
  spec.homepage    = "https://github.com/bowerbird-app/RecordingStudio_billing"
  spec.summary     = "Provider-agnostic billing foundation for Recording Studio"
  spec.description = "A Rails engine that provides provider-agnostic billing Recording Studio foundations, " \
                     "including Stripe as the default provider."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "flat_pack", "~> 0.1.134"
  spec.add_dependency "rails", "~> 8.1.0"
  spec.add_dependency "recording_studio", "~> 4.2"
  spec.add_dependency "recording_studio_accessible", "~> 0.7.0"
  spec.add_dependency "recording_studio_admin", "~> 2.0.1"
  spec.add_dependency "recording_studio_root_switchable", "~> 0.5.0"
  spec.add_dependency "recording_studio_webhooks", "~> 0.2.0"
  spec.add_dependency "stripe", "~> 19.5"
end
