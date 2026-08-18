# RecordingStudio Core v4.0.0 Update Summary

## Changes Made

### RecordingStudio Dependency

- Updated the dummy app dependency to `github: "bowerbird-app/RecordingStudio", tag: "v4.0.0"`.
- Updated Accessible to the RS 4 support branch (`0.6.0`) and Root Switchable to `v0.4.0`.
- Updated FlatPack to `v0.1.132`.
- Updated the dummy app lockfile and root gem lockfile to Rails `8.1.3.1` and current compatible gems.

### v4 Host Wiring

- Kept strict declaration enforcement enabled with `config.require_recordable_declarations = true`.
- Enabled `:accessible` on `Workspace` via `RecordingStudio.enable_capability`.
- Added Accessible initializer with `access_actor_types = ["User"]`.
- Installed `harden_recording_studio_indexes_and_constraints` for unique-root and lookup indexes.
- Recreated `recording_studio_accesses` for Accessible grant recordables (core had previously dropped it).
- Cascade-delete root switchable selections when a root recording is removed.
- Set `config.require_actor = !Rails.env.test?` as a recommended write hardening default.

### Tests And Docs

- Updated schema/capability coverage for Accessible + harden indexes.
- Refreshed README, changelog, configuration/install docs, and migration notes for RecordingStudio 4.

## Notes

RecordingStudio 4.0 removes `Recording` default ordering, makes Events append-only at the AR layer, and hardens query escape hatches. Accessible 0.6 requires RecordingStudio `~> 4.0`. Until Accessible `0.6.0` is tagged on main, pin the published RS 4 support branch.
