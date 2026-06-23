# Plugin install at image-build time

Claude Code plugins live under `~/.claude/plugins/` and are loaded automatically when claude starts (registered via `installed_plugins.json` written by `claude plugin install`). Copying a macOS-host `~/.claude/plugins/` tree into a Linux container fails: any plugin shipping native binaries or platform-specific `node_modules` won't run. Bind-mounting `~/.claude` (Docker Sandbox's recipe) hits the same problem and additionally leaks unrelated session state.

We declare plugins in the profile manifest and install them **fresh inside the container at image build time** using Claude Code's own CLI.

## Schema

```yaml
plugins:
  marketplaces:
    - jarrodwatts/claude-hud           # github user/repo
    - https://example.com/marketplace.git
  install:
    - claude-hud@jarrodwatts-claude-hud
```

Both sublists are explicit (`claude plugin install <name>@<marketplace>` requires the marketplace to be registered first; this surfaces the dependency rather than parsing it implicitly).

claude-code's built-in profile ships with an empty plugin set. Users opt in via workspace override (`.rp/agents/claude-code/manifest.yaml`).

## Build-time flow

`scripts/build-project-image.sh` emits, AFTER the profile's `install.sh` runs (so the `claude` binary is on PATH), a Dockerfile RUN block that:

1. Sets `HOME=/tmp/rp-plugin-stage` so `claude plugin install` writes to a staging dir, not the image's real `/home/<user>` (which gets shadowed by the runtime volume mount).
2. Runs one `claude plugin marketplace add <ref>` per `plugins.marketplaces` entry.
3. Runs one `claude plugin install <ref>` per `plugins.install` entry.
4. As root, copies `/tmp/rp-plugin-stage/.claude/*` into the seed location for the volume that covers `/home/<user>/.claude` (the claude-home volume by default; resolved via the same `volume_seed_target` helper that routes `files:` and `instructions_dst`).
5. Removes the staging dir.

If no volume covers `/home/<user>/.claude`, the build prints a WARN to stderr and skips plugin install. (A profile with `plugins:` but no covering volume is misconfigured — the plugins would be installed into the image filesystem but invisible inside the container once the volume mount shadows them.)

## Init-time merge seed

Pre-this-ADR, `rp-init.sh` seeded a volume from `/usr/local/share/rp/seed/<vol>/` ONLY when the mounted volume was empty. That's correct for first-create + agent settings but wrong for plugin updates: rebuild the image with a new plugin, `rp destroy && rp create`, init sees a non-empty volume (left over from the prior session), skips seeding entirely → new plugin missing.

The fix: per-file merge. Walk every file in the seed dir; copy each one that's missing in the mounted volume. Existing files are preserved (agent writes, prior plugin state with user config, etc.); newly-stashed plugin files appear on next create without needing `rp purge`.

Removals aren't honored — uninstalling a plugin from a profile + rebuilding doesn't remove it from existing volumes. Acceptable; users running `rp purge` get a clean slate.

## Why not at create time?

Considered + rejected (Q1).

- **Pro create-time:** per-workspace plugin lists become cheap (no image rebuild for changes).
- **Con create-time:** every `rp create` hits the network (GitHub, marketplace registries). Offline machines block. Build artifact stops being self-contained. Re-installs hammer the marketplace.

The build-time model matches rp's existing edit-config cycle: agent / user / resources / fuse cache all require `rp destroy && rp create` to take effect, with image rebuild. Plugins fit the same pattern.

## Why not just claude-hud / a default set?

Considered + rejected (Q3). The built-in claude-code profile keeps `plugins:` empty. Reasons:

1. **Reduces image bloat and build time** by default. Users who don't want plugins don't pay.
2. **Plugin selection is highly personal** (one user wants claude-hud, another wants slash-command bundles, etc.). Shipping any default risks adding what one user wants and another finds noisy.
3. **Workspace override is the easy opt-in:** users copy the built-in manifest and add `plugins:`. ADR-0007's profile-resolution rules already cover this path.

## Risks

- **Marketplace ref validation is lenient.** `validatePluginRef` rejects shell metachars + `..` but accepts arbitrary git refs / URLs. `claude plugin marketplace add` itself errors loudly on actual bad refs, so the lint is just first-line filtering.
- **Build-time network access.** Apple Container's builder VM needs network for the marketplace clone. Same constraint as `apt-get update` already present in the overlay; not a new failure mode.
- **`claude plugin install` writes to `~/.claude.json` too** (records install metadata). The host-files import for `~/.claude.json` (ADR-0015) happens at create-time AFTER the volume is seeded — so host's claude.json overwrites the build-time-installed metadata. May cause claude to forget the plugin was installed. Verified empirically: users who pull host's `.claude.json` AND install plugins via this mechanism get both — the merged `~/.claude/plugins/installed_plugins.json` (from seed) drives plugin loading, and `~/.claude.json` (from host) drives session/auth state. Two separate files, separate concerns.

## Tests

- `rp-fuse/profile_test.go`: schema parsing, injection rejection, field accessor output.
- Integration: deferred. End-to-end plugin install test requires network access from the Apple Container builder VM (works locally but flaky in CI without arrangements). Manual smoke verified on user's macOS host with `claude-hud` declared in a workspace override.
