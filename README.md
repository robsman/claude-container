# claude-container — Run Claude Code safely in Apple Containers

A macOS tool for running Claude Code in isolated Apple Container instances. Each container is anchored to a folder on your Mac. A custom FUSE driver (`rp-fuse`) lets you selectively shadow paths so build artifacts and secrets never touch the host filesystem.

Requires Apple Silicon + macOS 26+.

---

## What you get

- **Claude Code in a sandbox.** The container is started with `--dangerously-skip-permissions` but can only touch what you let it touch.
- **Per-folder containers.** `cd ~/my-project && ccr claude` auto-creates `claude-my-project` and mounts that folder as `/workspace`. Stop, start, destroy — your files stay on the Mac.
- **`.rp/shadow` filtering.** A gitignore-style file at your workspace root tells `rp-fuse` which paths are container-local. Host secrets (`.env.local`, `.aws/credentials`) stay invisible. Build artifacts (`node_modules`, `.venv`, `target`) live only in the container, so architecture mismatches and `rm -rf node_modules` cycles never pollute the host.
- **Real security boundary.** The container's user has no `sudo` and no capabilities. The host bind is hidden in a root-only mount; `coder` cannot bypass the shadow layer even with intent. See `docs/adr/0005-shadow-as-security-boundary-via-drop-sudo.md`.

---

## Prerequisites

- Apple Silicon Mac (M1 or newer), macOS 26+
- [Homebrew](https://brew.sh)
- `brew install container jq just`
- A Claude Pro/Max subscription, or an Anthropic API key

---

## One-time setup

```bash
git clone https://github.com/robsman/claude-container.git ~/repos/claude-container
cd ~/repos/claude-container
./ccr setup           # installs Apple Container + jq, starts services + the builder VM
./ccr build-base      # builds the rp-base image (small; required for any project image)
./ccr build           # builds the default claude-container image
./ccr build-host      # cross-builds the host-side rp-fuse binary (used by `ccr lint` + project image builds)
```

The builder VM is a long-lived Apple Container that runs all `container build` invocations. `ccr setup` brings it up at the size given by `builder_memory` in the Justfile (default 8G). To change the size later, edit the Justfile and run `ccr builder-reset` — `container build -m` does NOT renegotiate a running builder.

Then put `ccr` on your `PATH` (symlink it into `/usr/local/bin` or add the repo dir to `PATH`). If you cloned somewhere other than `~/repos/claude-container`, set `CLAUDE_CONTAINER_DIR` to the actual path.

---

## Daily use

```bash
cd ~/my-existing-repo
ccr claude                 # auto-creates the container, opens Claude Code inside it
ccr shell                  # bash shell into the cwd-anchored container
ccr login                  # one-time Claude subscription login
ccr stop                   # pause
ccr start                  # resume
ccr destroy                # remove container (host files untouched)
ccr list                   # show all claude-* containers + their workspace paths
ccr lint                   # check the .rp/shadow file in cwd (see below)
```

Pass an explicit name as the last argument if you want a different name from the folder basename:

```bash
ccr create my-name
ccr claude  my-name "summarize the README"
```

---

## `.rp/shadow` — selective shadowing

Put a `.rp/shadow` file at the root of any workspace to filter paths between host and container. Syntax is a strict subset of `.gitignore`:

```
# secrets — host versions stay invisible inside the container
.env.local
.aws/credentials
.ssh/id_rsa

# build artifacts — container-local, never pollute the host
node_modules
.venv
target
*.log

# anchored examples
/secret              # only matches /secret at workspace root
build/               # matches dir named "build" at any depth
**/cache             # matches "cache" at any depth (explicit deep-match)
```

Rules:

- `*`, `**`, `?`, `[abc]` globs
- Leading `/` or any mid-pattern `/` anchors to workspace root
- Trailing `/` restricts to directories
- No negation (`!pattern`) — skipped with a warning
- `#` comments only at the start of a line

For every matched path:

- Host's file/dir is invisible (`stat` returns ENOENT until the container writes there).
- Container creates/writes/deletes go to `/var/lib/rp/shadow/<rel-path>`, never to the host bind.
- `rm -rf node_modules && npm install` cycles work normally — host stays untouched.
- The shadow store survives `ccr stop`/`start`. `ccr destroy` wipes it.

Edit `.rp/shadow` from the host. Inside the container it is **read-only** — Claude can `cat` it to understand what's filtered but cannot modify the ruleset. Changes require `ccr stop && ccr start` to take effect.

See `.rp.example/shadow` for a copy-paste-ready starting point.

### `ccr lint`

Sanity-check your `.rp/shadow` before activating it:

```bash
$ cd ~/my-project
$ ccr lint
.rp/shadow:1: node_modules     OK    literal-unanchored
.rp/shadow:2: *.log            OK    glob-unanchored
.rp/shadow:3: !keep            WARN  negation not supported; skipped

Summary: 2 active, 1 warning, 0 error

$ ccr lint --match "packages/lib-a/node_modules"
...
Match report for path "packages/lib-a/node_modules":
  matched by line 1: node_modules (literal-unanchored)
```

Exit code 1 if any error-status lines — usable as a pre-commit hook or CI check.

---

## Per-project images

The default workspace image is `claude-container` (Node 22 + Python+uv + R + DuckDB + just + Claude CLI). If you want a different base — a Python-only image, a different Node version, your own pre-built tooling — drop a `.rp/config.yaml` in your workspace.

### Pull a pre-built image
```yaml
# .rp/config.yaml
image: python:3.12-slim-bookworm
```
On first `ccr claude` ccr composes a thin layer onto the image (fuse3, rp-fuse, mount points, user) and tags the result `claude-<basename>:latest-ccr`. Subsequent starts reuse the composed image.

### Build locally from your own Dockerfile
```yaml
# .rp/config.yaml
build:
  context: .                # relative to .rp/
  dockerfile: Dockerfile
  args:
    NODE_VERSION: "22"
```
…or, equivalent shorthand without a config file: just drop a `.rp/Dockerfile`. ccr will build it and apply the overlay.

### Adopt an existing user from the base image
Some images establish their own user (`node:22-bookworm` has a `node` user, etc.). Adopt it via:
```yaml
image: node:22-bookworm
user: node
```
The overlay validates the user exists in the base image, has uid ≠ 0, and is not listed in any sudoers file. If any check fails, the image build fails loudly. Default (no `user:` set) creates a fresh `coder` user.

### Quick start from the template
```bash
cd ~/my-project
cp -r ~/repos/claude-container/.rp.example .rp
$EDITOR .rp/shadow .rp/config.yaml
ccr claude              # first run builds the project image
```

### Constraints
- **Debian/Ubuntu bases only** (v1). The ccr overlay installs `fuse3` via `apt-get`, so Alpine, RHEL, Arch, distroless, etc. bases are rejected up front with a clear error pointing at ADR-0006. Good bases: `debian:bookworm-slim`, `ubuntu:24.04`, `node:*-bookworm`, `python:*-slim-bookworm`. If you need Alpine-flavored tooling today, write a Debian-based `.rp/Dockerfile` that installs the equivalent packages via apt.
- `.rp/config.yaml` recognised keys: `image`, `build` (with `context`, `dockerfile`, `args`), `user`, `resources.memory`, `resources.cpus`, `fuse.cache`. Anything else parse-errors with line numbers — `depends_on`, `ports`, `environment`, etc. are explicitly not supported yet.
- Workspaces without a `.rp/config.yaml` and without a `.rp/Dockerfile` use the default `claude-container` image, same as before.

### Edit-config workflow
Changes to `.rp/config.yaml` or `.rp/shadow` take effect at container CREATE time. To pick up edits:

```bash
ccr destroy && ccr claude     # rebuilds the project image + reapplies config
```

`ccr stop` + `ccr start` is enough only for re-reading `.rp/shadow` rules (since rp-fuse re-reads them at every start). Anything that affects image composition (image:, build:, user:, resources:) requires `destroy + create`.

### Diagnosing FUSE issues
Set `RP_DEBUG=1` in the host shell when creating the container to enable verbose FUSE logging inside rp-fuse:

```bash
RP_DEBUG=1 ccr create myname    # forwarded into the container as -e RP_DEBUG=1
ccr logs myname                  # the verbose stream
```

---

## What happens inside the container

- You run as the configured user (default `coder` uid 1000), **no sudo**. System packages must be added at image-build time (edit `Dockerfile` or your per-project `.rp/Dockerfile`, run `ccr rebuild`).
- `/workspace` is a FUSE mount served by `rp-fuse`. Passthrough paths reach the host bind; shadowed paths live in a container-local store.
- Tools available depend on the image:
  - **Default `claude-container` image**: `git`, `python3 + uv`, `node 22`, `R`, `DuckDB`, `just`, `build-essential`, `claude`.
  - **Per-project image (`.rp/config.yaml` with `image:` or `build:`)**: only what the base image ships, plus the ccr overlay essentials (`fuse3`, `rp-fuse`, `rp-init.sh`, the configured user). Even the Claude CLI is NOT present unless your base image or `.rp/Dockerfile` installs it.
  - **Workaround if you want default tooling + a few extras**: `FROM claude-container:latest` in your `.rp/Dockerfile` and add what you need. The ccr overlay is layered on top regardless.
- Auth: `ccr login` (subscription) or `ANTHROPIC_API_KEY` in a `.env` next to the Justfile.

---

## Security model

Read `docs/adr/0005-shadow-as-security-boundary-via-drop-sudo.md` for the full reasoning. Short version:

- Default container view shows the workspace mediated by `rp-fuse`. Shadowed paths return ENOENT to the container; only the container's own writes survive there.
- `/workspace-real` (the raw host bind) is overlaid with a tmpfs in the container's mount namespace. `coder` cannot read it.
- The shadow store and the host bind both live under `/var/lib/rp/` (mode 0700, root-only). `coder` cannot traverse it.
- `coder` has no capabilities and no sudo, so it cannot `umount` the tmpfs or escalate to root to bypass any of the above.

What this means concretely: if you list `.env.local` in `.rp/shadow`, the contents of your host `.env.local` are unreachable to anything running inside the container.

---

## Architecture

```
Dockerfile.base          rp-base: debian-slim + fuse3 + rp-fuse + rp-init.sh + coder
Dockerfile               claude-container (FROM rp-base) + Node/Python/R/DuckDB/just/Claude CLI
Justfile                 ccr recipes (build-base / build / build-host / create / start / claude / lint / ...)
ccr                      thin wrapper; dispatches lint locally, everything else via just
rp-fuse/                Go source: FUSE driver + lint + config (compose-subset YAML) + tests
scripts/
  build-project-image.sh project-image overlay builder (called by _ensure / create)
config/
  CLAUDE.md              in-container guidance (baked into the default image)
  claude-settings.json   in-container Claude settings (bypassPermissions allowlist)
  rp-init.sh            PID 1: sets up the shadow boundary, execs rp-fuse
docs/
  adr/                   architecture decision records
  agents/                config for matt-pocock-style engineering skills
CONTEXT.md               domain vocabulary (Shadow, Project image, ccr overlay, ...)
.rp.example/
  shadow                 copy-paste-ready .rp/shadow template
```

See `CLAUDE.md` for the developer-facing summary and `CONTEXT.md` for the vocabulary used across docs and code.

---

## Tips

- `ccr list` shows every container with the host folder it's anchored to. Run this if you forget which container goes with which project.
- If `ccr` complains about a collision when you `cd` into a different folder, it means a container with that basename already exists anchored elsewhere. Use an explicit name or destroy the old one.
- For one-off prompts: `ccr claude "what does this repo do?"` runs Claude Code with that prompt and exits.
- Updating an API key: edit `.env` in the claude-container repo. Existing containers carry the value baked in at create time — `ccr destroy && ccr claude` to pick up a new value.

---

## Getting help

- Read `CLAUDE.md` for the architecture overview and `docs/adr/` for the decisions behind it.
- `ccr lint` to debug rule files.
- File issues on the GitHub repo.
