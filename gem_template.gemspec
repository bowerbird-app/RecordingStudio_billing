# frozen_string_literal: true

require_relative "lib/gem_template/version"

Gem::Specification.new do |spec|
  spec.name        = "gem_template"
  spec.version     = GemTemplate::VERSION
  spec.authors     = ["Bowerbird"]
  spec.homepage    = "https://github.com/bowerbird-app/RecordingStudio_gem_template"
  spec.summary     = "Recording Studio addon template for Rails engines"
  spec.description = "An internal template for building Recording Studio addons with Rails 8.1, " \
                     "UUID-backed PostgreSQL models, TailwindCSS, and GitHub Codespaces support"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/bowerbird-app/RecordingStudio_gem_template"
  spec.metadata["changelog_uri"] = "https://github.com/bowerbird-app/RecordingStudio_gem_template/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", "~> 8.1.0"
end
