# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in recording_studio_billing.gemspec
gem "devise"
gem "flat_pack", github: "bowerbird-app/flatpack", ref: "c4e7581bad6a177c46aebc43c3575e1ff93706ff"
gem "recording_studio", github: "bowerbird-app/RecordingStudio", tag: "v4.2.0"
gem "recording_studio_accessible", github: "bowerbird-app/RecordingStudio_accessible", tag: "v0.7.0"
gem "recording_studio_admin", github: "bowerbird-app/RecordingStudio_admin", tag: "2.0.1"
gem "recording_studio_root_switchable", github: "bowerbird-app/RecordingStudio_root_switchable", tag: "v0.5.0"
gem "recording_studio_webhooks", github: "bowerbird-app/RecordingStudio_webhooks", tag: "v0.2.0"
gemspec

gem "puma"
gem "sprockets-rails"

group :development, :test do
  gem "debug"
  gem "pg"
  gem "simplecov", require: false
end

group :development do
  gem "rubocop", require: false
  gem "rubocop-rails", require: false
end

gem "stripe", "~> 19.5"
