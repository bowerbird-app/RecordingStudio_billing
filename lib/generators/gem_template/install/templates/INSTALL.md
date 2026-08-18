GemTemplate install complete.

Next steps:

1. Review config/initializers/gem_template.rb and set any required options.
2. If you use environment-specific settings, create config/gem_template.yml.
3. Install the engine migrations with `bin/rails generate gem_template:migrations`.
4. Apply the migrations with `bin/rails db:migrate`.
5. Run `bin/rails tailwindcss:build` if you use Tailwind CSS.
6. Mount routes are added at the configured mount path. Adjust auth, layout, and current actor integration to match your host app.
7. Keep RecordingStudio strict declarations enabled and add `recording_studio_recordable(...)` to every configured recordable before running `RecordingStudio.validate_recordable_declarations!`. On RecordingStudio 4 hosts, prefer `Recording.recent` / explicit `order:` and enable `:accessible` on roots that receive Accessible grants.