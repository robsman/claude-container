# `allow_sudo: true` — per-workspace bypass of the no-sudo invariant

ADR-0005 established the shadow boundary as a real security boundary: the container user has no sudo grant and no CAP_*, so it cannot `sudo umount` the FUSE layer or otherwise escape into the raw host bind. ADR-0009 added `strip_sudo: true` as an opt-in that keeps a devcontainer's ergonomic user (e.g. `node`) but rewrites the user's sudoers grants away.

But sometimes the user actually wants sudo inside. Concrete case: running `sudo apt-get install <extra-pkg>` inside the container during a session, without rebuilding the image. `strip_sudo` doesn't cover this — it removes the very capability the user is after.

`allow_sudo: true` is the third leg of the stool. Says "I know the shadow boundary is now weakened; the container's outer isolation (the VM boundary on Apple Container / the sandbox VM on Docker Sandbox) is still what protects the host — treat the shadow layer as a hint, not a security boundary in this workspace".

## Scope

Two enforcement points, both flip together:

1. **Overlay build** (`scripts/build-project-image.sh`). The default emits a Dockerfile RUN that greps for the user in sudoers and `exit 1`s. With `allow_sudo: true` the RUN is omitted entirely; the build passes even when the user is in `wheel`/`sudo`.
2. **Container runtime** (`config/rp-init.sh`). PID 1 (root) re-asserts the invariant. Same grep. With `allow_sudo: true`, `resolve-create-args.sh` forwards `RP_ALLOW_SUDO=1` into the container and init.sh skips the refusal.

The `RP_ALLOW_SUDO=1` env var already existed (was intended as a Docker-Sandbox-only escape hatch, ADR-0010 status section). This ADR promotes it to a first-class per-workspace config field — the env-only form was documented but had no build-time counterpart, so it silently failed for local Apple Container users. This aligns the two enforcement points behind one field.

## Merge with local override

Standard rule from ADR-0017: scalars local wins. A workspace can commit `allow_sudo: false` (or omit the field, same thing) and a developer's `config.local.yaml` can set `allow_sudo: true` for casual work without churning the shared config.

## Interaction with strip_sudo

Mutually exclusive in practice, but not enforced by the parser (the fields ARE combinable — strip runs first, then allow — but there's nothing left for allow to bypass because strip removed the grants). If both are set, the behavior collapses to `strip_sudo: true` (grants stripped; user has no sudo; runtime check passes because it's a no-sudo user; allow_sudo is a no-op). Documenting this as "don't set both" is cheaper than adding a config-level rejection.

## Rejected alternatives

- **Env-only bypass (`RP_ALLOW_SUDO=1`).** Already existed for Docker Sandbox. Never gated the BUILD-time RUN, so it appeared to work but failed at `container build` time. Confusing UX; this ADR promotes to a config field so both enforcement points flip together.
- **A per-command flag (`rp create --allow-sudo`).** Ephemeral state, easy to forget between destroy+create cycles. Config-in-file is durable.
- **Config field that only affects runtime.** Same trap as the env var. Both build and runtime must respect the same knob.

## Boundary reminder

`allow_sudo: true` intentionally trades the shadow boundary for ergonomics. Suitable for:

- Single-user Mac with only trusted code in the container.
- Rapid iteration where re-image-building for every new apt package is friction.

Not suitable when:

- Container runs code from untrusted sources (agent output that might exfiltrate).
- Multi-tenant hosts (someone else's container on the same host could exploit).
- Compliance-motivated setups where the host bind must stay unreachable.

Prefer `strip_sudo: true` when you just want the devcontainer's default user without granting sudo. Prefer a plain `coder` user (no sudo grants in the image) when the base image is your choice.
