# Multi-agent profiles and project rename (Claude Code, OpenCode, …)

The project widens from a single-vendor tool (Claude Code in a container) to a vendor-neutral runner for any TUI coding agent — Claude Code, OpenCode, Codex CLI, Aider, future ones — sharing the same Apple-Container + FUSE-shadow boundary. The user picks an agent per workspace via `.rp/config.yaml`'s `agent:` field. The project + wrapper command rename from `claude-container` / `ccr` to `robo-pen` / `rp` follows from the widened scope.

## Tier-1 plugin shape: profile = directory of conventional files + manifest.yaml

A profile is a directory under either `agent.profiles/<name>/` (built-in, in this repo) or `<workspace>/.rp/agents/<name>/` (workspace override). It contains a `manifest.yaml` plus conventionally-named scripts (`install.sh`, `run.sh`, `run-gated.sh`, `login.sh`) and a `settings/` dir + `instructions.md` fragment. No code runs in the host process beyond YAML parsing; the agent's install + run is shell, executed inside the container at build / run time. We rejected Tier 0 (hard-coded `if name == "claude" ... else if name == "opencode" ...`) because it does not scale past 2-3 agents; we rejected Tier 2 (a versioned plugin protocol with loadable Go plugins or RPC) because nothing about the current extension points justifies the binary-plugin complexity. Tier 1 hits the sweet spot: a profile is a small directory, easy to vendor or override per workspace, no SDK churn, no version compatibility matrix.

Lookup is workspace-first. `<workspace>/.rp/agents/<name>/manifest.yaml` wins if present; otherwise `agent.profiles/<name>/`. Partial overrides (the workspace dir exists but `manifest.yaml` does not) fall through silently to the built-in; `rp lint` warns. The resolver runs at image-build time, not container start time, so the per-project image's contents are deterministic given the workspace's profile state.

## v1 ships exactly one built-in profile (claude-code); OpenCode is a workspace example

Every built-in profile is a maintenance burden — its `install.sh` is exposed to upstream installer changes, and shipping it implies "we keep this working." We avoid that for everything except claude-code, which is the default agent and back-compat target. OpenCode ships as `examples/opencode/.rp/agents/opencode/` instead — a copy-pasteable workspace override that proves the override mechanism works without committing the project to maintaining OpenCode's installer. The default `agent:` value is `claude-code`, so existing users see no behavioral change beyond the wrapper rename.

## Rename rationale: vendor-neutral, hard break, container prefix includes agent

`claude-container` claims one vendor in its name, which is now factually incorrect — the same tool runs OpenCode, Codex CLI, Aider. `robo-pen` is vendor-neutral (no agent name baked in), short enough to type as `rp`, and avoids the LLM-era "agent" hype. The rename is a hard break — no `ccr` symlink, no `.ccr/` fallback, no `CLAUDE_CONTAINER_DIR` deprecation warning. We pay the migration cost once. Migration is four commands; the README documents them.

The container prefix becomes `rp-<agent>-<basename>` (e.g. `rp-claude-code-myrepo` next to `rp-opencode-myrepo`). This lets the same workspace host parallel containers per agent — Claude Code and OpenCode side-by-side, comparable for the same project. `rp list` groups under `rp-` regardless of agent. The git repo identity is preserved (no fresh-`git init`); only the visible identifiers change.

Hard-break boundary: workspace `.ccr/` → `.rp/`. The internal sweep (`ccr-fuse` → `rp-fuse`, `/var/lib/ccr` → `/var/lib/rp`, `CCR_DEBUG` → `RP_DEBUG`, labels `ccr.host_path` → `rp.host_path`) is mechanical and uniform; ADRs 0001-0006 had their identifier references updated to match, but their historical reasoning is preserved.
