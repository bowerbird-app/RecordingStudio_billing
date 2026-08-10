# RecordingStudio Core v3.0.0 Update Summary

## Changes Made

### RecordingStudio Dependency

- Updated the dummy app dependency to `github: "bowerbird-app/RecordingStudio", tag: "recording_studio/v3.0.0"`.
- Updated the dummy app lockfile reference to RecordingStudio `3.0.0`.

### v3 Recordable Declarations

- Kept strict declaration enforcement enabled with `config.require_recordable_declarations = true`.
- Removed obsolete `config.include_children`.
- Added `recording_studio_recordable` declarations:
  - `Workspace`: `root: true`
  - `Folder`: `root: false`, allowed under `Workspace` or `Folder`
  - `Page`: `root: false`, allowed under `Workspace` or `Folder`

### Dummy App Seeds And Docs

- Seeds now create the workspace root through `RecordingStudio.root_recording_for`.
- Folder and page seeds are created with explicit `parent_recording` relationships.
- Removed seed references to core `Access` and `AccessBoundary` records.
- The recordable types docs page now uses v3 declaration/introspection APIs, including declaration validation, root eligibility, and allowed parent types.

### Tests

- Added Minitest coverage for:
  - `validate_recordable_declarations!`
  - `root_recordable_types`
  - `allowed_parent_types_for`
  - root recording creation
  - allowed child creation
  - child root rejection
  - parentless child validation failure

## Notes

RecordingStudio core v3.0.0 treats root/child hierarchy rules as explicit recordable declarations. Core Access, AccessBoundary, Movable, Copyable, and DeviceSession claims from older notes were removed from this template documentation.
