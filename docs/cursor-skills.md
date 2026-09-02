# Cursor skills in Cloud Agents

Cloud Agent Builds fetch the project skill pack. The repository does not vendor
the generated `SKILL.md` or plugin `*.mdc` files.

The repository tracks four boot files:

- `.cursor/environment.json` defines the Build hooks, terminals, and port.
- `.cursor/install.sh` provisions Ruby, PostgreSQL, dependencies, the dummy
  database, and CSS on a cold image. On a warm snapshot it skips that
  provision when Ruby, bundle, and Postgres are already usable. A skippable
  provision failure does not fail the Build. It always runs
  `.cursor/fetch-skills.sh` last.
- `.cursor/fetch-skills.sh` downloads the current skill and rule pack.
- `.cursor/start.sh` starts PostgreSQL on each environment boot.

At Build time, `.cursor/install.sh` runs `.cursor/fetch-skills.sh`. Cloud Agents
then load skills from `.cursor/skills/` and rules from `.cursor/rules/`. Both
directories are gitignored Build output.

The next Cloud Agent environment rebuild with Draft off runs this Build path
and loads the fetched pack. The hook fetches
[RecordingStudio_cursor_plugin](https://github.com/bowerbird-app/RecordingStudio_cursor_plugin)
and its configured skill sources. It never clones that repository into this
checkout.

The gemspec packages only `app`, `config`, `db`, and `lib`, plus the license,
Rakefile, and README. Cursor boot files and generated pack files do not ship in
the gem.

Repo-specific test guidance also lives in
[`.github/skills/minitest-workflow`](../.github/skills/minitest-workflow/SKILL.md).
That path is a GitHub skill. It is not part of the Cursor pack.
