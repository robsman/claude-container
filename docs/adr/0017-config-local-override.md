# `.rp/config.local.yaml` — per-developer overrides

Teams commit `.rp/config.yaml` so every member uses the same base image, agent, and shared settings. Individual developers still need personal additions: their plugins, host_files imports of their dotfiles, host_path_aliases pointing at their host home. Editing the shared file would force a churning commit dance ("I added my own claude-hud install, please don't merge this").

Following the convention from docker-compose's `compose.override.yaml` + Claude Code's own `settings.local.json`, `.rp/config.local.yaml` is the per-developer override. Same schema. Gitignored. Layered on top of `config.yaml` at parse time inside `rp-fuse`.

## Merge rules

| Field type | Behavior |
|---|---|
| Scalars: `image`, `user`, `agent`, `strip_sudo`, `fuse.cache` | local wins when set |
| Lists: `host_files`, `host_keychain`, `host_aliases`, `host_path_aliases`, `plugins.marketplaces`, `plugins.install` | append (local entries added after shared) |
| Maps: `resources`, `fuse`, `plugins` | deep merge — per-key, local wins for scalars, lists append |

Local-wins-for-scalars + append-for-lists matches the most common use case: "my personal extras don't replace the team's defaults, they extend them". A developer can still REPLACE a scalar (e.g. bump memory) by setting it in local. They cannot REMOVE list entries via local — would need to edit the shared config.

Validation runs once, on the merged result. Constraints that reject `image:` + `build:` together, etc., still apply.

## Implementation

Single change in `rp-fuse/config.go`. `ParseProjectConfig` now:

1. Parses the base path normally.
2. Computes the sibling `config.local.yaml` path.
3. If it exists, parses it as a `ProjectConfig` and calls `base.Merge(local)`.
4. Validates the merged result.

All existing field accessors (`config field <name>`) transparently see merged data — no caller changes.

`Merge(other *ProjectConfig)` is the explicit method; tests cover both list-append + scalar-override semantics.

## Convention bundle

`.rp.example/.gitignore` (new) lists `config.local.yaml`. `rp init` copies the whole template dir including dotfiles, so the gitignore lands at `.rp/.gitignore` automatically. Git honours nested gitignores; `config.local.yaml` stays out of commits.

## Rejected alternatives

- **`include:` directive in config.yaml.** Would let users explicitly opt in / chain multiple files. More flexible, but indirection makes "where's this setting coming from" harder. The sibling-by-convention is zero-knob.
- **Multiple layer chain (system + user + workspace + local).** Overkill for the current threat model. Two layers cover the team-share / personal-additions split, which is the demand.
- **Replace-semantics for lists.** Would force users to copy entire shared lists just to add one entry. Append matches the user's mental model ("my additions").
- **Renaming to `config.override.yaml`** (docker-compose convention). `local` reads cleaner alongside the existing `settings.local.json` convention in Claude Code itself.

## Tests

`rp-fuse/config_test.go` covers: list-append (host_path_aliases + plugins.install), scalar-override (image + resources.memory), no-local-no-change.
