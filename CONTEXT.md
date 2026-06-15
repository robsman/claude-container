# robo-pen

Tool for running coding agents (Claude Code, OpenCode, …) inside isolated Apple Container instances. The host directory you invoke `rp` from is bind-mounted into the container; `rp-fuse` overlays a rule-aware filesystem on top so selected paths are kept container-local.

## Language

### Filesystem boundary

**Shadow**:
A path listed in `.rp/shadow`. The host's content at that path is invisible to the container, and the container's reads/writes go to a parallel container-local store that never touches the host filesystem.
_Avoid_: ignore (misleading — the path is not ignored, just rerouted), mask (misses the writable half), private (the path also exists on host), overlay (collides with kernel `overlayfs`).

**Shadow store**:
The container-local directory backing all shadowed paths, located at `/var/lib/rp/shadow`. Mirrors the workspace path structure: a shadow for `a/b/c` lives at `/var/lib/rp/shadow/a/b/c`. Survives `rp stop`/`start`; wiped on `rp destroy`.
_Avoid_: overlay store, private store.

**Passthrough**:
A path NOT matched by any `.rp/shadow` rule. Reads and writes go to the host bind mount; edits propagate bidirectionally between host and container.
_Avoid_: passthrough mount (sounds like a filesystem feature), host-backed.

**Workspace**:
The container-visible `/workspace` directory. Composed by `rp-fuse` from passthrough paths (host-backed) plus shadowed paths (store-backed).

**Workspace-real**:
The raw host bind mount at `/workspace-real`. Implementation detail — the user / agent should not interact with it directly.

**Shadow rules**:
The pattern set in `.rp/shadow` that determines which paths are shadowed. Syntax is a strict subset of `.gitignore`: same anchoring semantics (leading `/` and mid-slash both anchor to root), `*` / `**` / `?` / `[…]` globs, trailing `/` for directory-only. **Negation (`!pattern`) is NOT supported** and is silently skipped with a warning. The container sees the file but cannot modify it (writes return EROFS); only the host can edit the rules.
_Avoid_: ignore patterns, ccrignore rules.

### Image layers

**Base image**:
The shared `rp-base` image, built once per robo-pen release via `rp build-base`. Holds the rp-fuse binary, the rp-init.sh script, the agent-agnostic `00-container.md` fragment, and the bits required by the rp overlay (fuse package, fuse.conf, mount-point directories). Project images derive from it.
_Avoid_: robo-pen image, root image.

**Project image**:
The image actually run by a given container. Composed per workspace from the user's chosen base (either `image:` in `.rp/config.yaml`, `build:` from `.rp/Dockerfile`, or the default `robo-pen-default`) plus the rp overlay layer. Tagged `<container-name>:latest-rp`.
_Avoid_: container image, per-repo image.

**rp overlay**:
The thin layer always applied on top of a user's chosen image. Validates (or creates) the container user, ensures `/etc/fuse.conf` allows non-root mounts, creates `/var/lib/rp` at mode 0700, copies `rp-fuse` + `rp-init.sh` from the base image, and runs the configured agent profile's install + instruction-compose. The layer is what makes any user image runnable as a rp container.
_Avoid_: rp layer, decorator layer.

**Container user**:
The unprivileged identity the container runs interactive sessions as. Defaults to `coder` (uid 1000, created by the rp overlay). May be overridden via `.rp/config.yaml`'s `user:` field to adopt an existing user from the base image. rp enforces the invariant that this user has uid ≠ 0 and is not listed in any sudoers file; build fails otherwise.
_Avoid_: workspace user, exec user.

### Agent profiles

**Agent**:
The coding TUI a container runs (e.g. Claude Code, OpenCode). One container runs one agent, selected via `.rp/config.yaml`'s `agent:` field (default: `claude-code`).
_Avoid_: tool, assistant, model, robot.

**Agent profile** (or just **profile**):
A bundle that defines everything needed to make one agent runnable inside the rp overlay: a `manifest.yaml`, an `install.sh`, a `run.sh` (and optional `run-gated.sh`, `login.sh`), `settings/` files, and an `instructions.md` fragment. The overlay COPYs all of these into the project image at build time.
_Avoid_: agent definition, plugin, recipe.

**Built-in profile**:
A profile that ships in this repo under `agent.profiles/<name>/`. v1 ships exactly one: `claude-code`. Adding a new built-in requires a PR.
_Avoid_: bundled profile, vendor profile.

**Workspace profile** (or **workspace override**):
A profile that lives in the workspace at `.rp/agents/<name>/`. Takes precedence over a built-in of the same name when `manifest.yaml` is present. Lets users ship their own agent (or override a built-in for one project) without patching robo-pen.
_Avoid_: user profile, local profile, custom profile.

**Profile manifest**:
The `manifest.yaml` at the root of a profile bundle. Declares the profile's `name`, `description`, `env:` allow-list (host env vars forwarded into the container), `files:` (static files COPYed into the image), `instructions_dst` (path of the composed instruction file), and `entrypoints:` (overrides for the conventional sibling-named scripts).
_Avoid_: profile config, profile spec.

**Composed instructions**:
The file written by the overlay at the profile's `instructions_dst` (e.g. `/home/coder/.claude/CLAUDE.md` for claude-code). Composed at build time by concatenating `/etc/rp/instructions/*.md` in lexical order: `00-container.md` (from rp-base), `10-toolchain.md` (from the project image), `20-agent.md` (the profile's `instructions.md`), and optionally `30-workspace.md` (from a workspace's `.rp/instructions.md`).
_Avoid_: agent prompt, CLAUDE.md (too specific).
