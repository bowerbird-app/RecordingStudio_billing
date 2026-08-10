# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in recording_studio_billing.gemspec
gem "devise"
gem "flat_pack", github: "bowerbird-app/flatpack", tag: "v0.1.129"
gem "recording_studio", github: "bowerbird-app/RecordingStudio", tag: "recording_studio/v3.0.0"
gem "recording_studio_accessible", github: "bowerbird-app/RecordingStudio_accessible", tag: "0.3.1"
gem "recording_studio_admin", github: "bowerbird-app/RecordingStudio_admin", tag: "1.1.0"
gem "recording_studio_root_switchable", github: "bowerbird-app/RecordingStudio_root_switchable", tag: "v0.3.1"
gem "recording_studio_webhooks", github: "bowerbird-app/RecordingStudio_webhooks", tag: "v0.1.0"
gemspec

gem "puma"
gem "sprockets-rails"

group :development, :test do
  gem "debug"
  gem "simplecov", require: false
end

group :development do
  gem "rubocop", require: false
  gem "rubocop-rails", require: false
end
