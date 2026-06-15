# claude-container

Tool for running Claude Code inside isolated Apple Container instances. The host directory you invoke `ccr` from is bind-mounted into the container; `rp-fuse` overlays a rule-aware filesystem on top so selected paths are kept container-local.

## Language

**Shadow**:
A path listed in `.rp/shadow`. The host's content at that path is invisible to the container, and the container's reads/writes go to a parallel container-local store that never touches the host filesystem.
_Avoid_: ignore (misleading — the path is not ignored, just rerouted), mask (misses the writable half), private (the path also exists on host), overlay (collides with kernel `overlayfs`).

**Shadow store**:
The container-local directory backing all shadowed paths, located at `/var/lib/rp/shadow`. Mirrors the workspace path structure: a shadow for `a/b/c` lives at `/var/lib/rp/shadow/a/b/c`. Survives `ccr stop`/`start`; wiped on `ccr destroy`.
_Avoid_: overlay store, private store.

**Passthrough**:
A path NOT matched by any `.rp/shadow` rule. Reads and writes go to the host bind mount; edits propagate bidirectionally between host and container.
_Avoid_: passthrough mount (sounds like a filesystem feature), host-backed.

**Workspace**:
The container-visible `/workspace` directory. Composed by `rp-fuse` from passthrough paths (host-backed) plus shadowed paths (store-backed).

**Workspace-real**:
The raw host bind mount at `/workspace-real`. Implementation detail — the user/Claude should not interact with it directly.

**Shadow rules**:
The pattern set in `.rp/shadow` that determines which paths are shadowed. Syntax is a strict subset of `.gitignore`: same anchoring semantics (leading `/` and mid-slash both anchor to root), `*` / `**` / `?` / `[…]` globs, trailing `/` for directory-only. **Negation (`!pattern`) is NOT supported** and is silently skipped with a warning. The container sees the file but cannot modify it (writes return EROFS); only the host can edit the rules.
_Avoid_: ignore patterns, ccrignore rules.

**Base image**:
The shared `rp-base` image, built once per claude-container release via `ccr build-base`. Holds the rp-fuse binary, the rp-init.sh script, and the bits required by the ccr overlay (fuse package, fuse.conf, mount-point directories). Project images derive from it.
_Avoid_: claude-container image, root image.

**Project image**:
The image actually run by a given container. Composed per workspace from the user's chosen base (either `image:` in `.rp/config.yaml` or `build:` from `.rp/Dockerfile`) plus the ccr overlay layer. Tagged `<source-name>:<source-tag>-ccr`.
_Avoid_: container image, per-repo image.

**ccr overlay**:
The thin layer always applied on top of a user's chosen image. Validates (or creates) the container user, ensures `/etc/fuse.conf` allows non-root mounts, creates `/var/lib/rp` at mode 0700, and copies `rp-fuse` + `rp-init.sh` from the base image. The layer is what makes any user image runnable as a ccr container.
_Avoid_: ccr layer, decorator layer.

**Container user**:
The unprivileged identity the container runs interactive sessions as. Defaults to `coder` (uid 1000, created by the ccr overlay). May be overridden via `.rp/config.yaml`'s `user:` field to adopt an existing user from the base image. ccr enforces the invariant that this user has uid ≠ 0 and is not listed in any sudoers file; build fails otherwise.
_Avoid_: workspace user, exec user.
