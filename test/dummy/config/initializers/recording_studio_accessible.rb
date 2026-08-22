# frozen_string_literal: true

RecordingStudioAccessible.configure do |config|
  config.access_actor_types = ["User"]

  config.avatar_resolver = lambda do |access_holder|
    next unless access_holder.is_a?(User)

    email = access_holder.email.to_s.strip
    next if email.blank?

    {
      name: email.split("@").first.tr("._-", " ").squish.titleize,
      alt: email
    }
  end
end
