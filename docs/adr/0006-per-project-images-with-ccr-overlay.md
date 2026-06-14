# Per-project images with ccr overlay

Each ccr workspace gets its own image. The image is composed at build time from the user's chosen base (a pre-built reference or a `.ccr/Dockerfile`) plus a thin "ccr overlay" that adds the bits required for a ccr container to actually run.

## Why per-project

A single global image cannot satisfy every project: one wants R + DuckDB, another wants Rust + sqlite, another wants minimal Alpine. Editing the shared Dockerfile to accommodate everyone bloats the image and creates merge pressure. Per-project means each workspace owns its toolchain.

## Why an overlay, not a base-Dockerfile inherit pattern

A user-specified `image: node:22-bookworm` is a raw upstream image — it has no `coder` user, no `ccr-fuse`, no `ccr-init.sh`, no `/etc/fuse.conf` allow_other. Running it directly fails because PID 1 = `/usr/local/bin/ccr-init.sh` does not exist. Two choices:

1. Force users to write `FROM claude-container:latest` in every `.ccr/Dockerfile`. Tedious, easy to forget, breaks the `image:` case entirely.
2. Always wrap user's image with a ccr overlay layer that adds the required bits.

We chose (2). The overlay is a small templated Dockerfile applied at build time; the output is tagged `<source>:<source-tag>-ccr`. Users define their image freely; ccr guarantees ccr-runnability.

## Config

`.ccr/config.yaml` uses a subset of `docker-compose` service-level field names (no `services:` wrapper, single service). v1 supports `image`, `build` (with `context`, `dockerfile`, `args`), and `user`. Unsupported keys produce explicit "not yet supported" errors rather than silent ignores. We picked compose-style field names because the OCI ecosystem (Docker, Podman, nerdctl) treats this as the de facto standard; Apple Container provides no native equivalent.

## Container-user flexibility

Some base images establish their own conventional user (`node:22` → `node`, etc.). v1 lets `.ccr/config.yaml` set `user:` to adopt that user. When set, the overlay validates at build time that the named user exists, has uid ≠ 0, and is not listed in any sudoers file. Runtime re-validates. The unprivileged-user invariant of the shadow boundary (ADR-0005) is preserved regardless of which image the user picks.

## Build pipeline

1. `ccr build-base` (one-time, after install / update of claude-container) builds the `ccr-base` image holding `ccr-fuse`, `ccr-init.sh`, and the dependencies the overlay needs.
2. `ccr build` (run in any project workspace) reads `.ccr/config.yaml` and `.ccr/Dockerfile`:
   - if `image:` is set, runs an overlay-only build on top of that image
   - if `build:` is set or `.ccr/Dockerfile` is present, builds the user's image first, then the overlay
   - otherwise no project image is built; the container uses `ccr-base` directly
3. Containers reference the resulting `:<tag>-ccr` image.

## Hard switch on migration

No backwards compatibility with the pre-overlay design. Existing in-development containers must be `ccr destroy`'d; `.ccrshadow` files moved to `.ccr/shadow`; no users are on the legacy layout in production. We pay the rename cost once, up front.

## Debian/Ubuntu-only bases (v1 constraint)

The ccr overlay installs `fuse3` via `apt-get`. Alpine, RHEL, Arch, distroless, and other non-Debian bases will fail the overlay build. To surface this as a friendly error rather than a cryptic `apt-get: not found`, `scripts/build-project-image.sh` probes the source image with `[ -f /etc/debian_version ]` before composing the overlay; non-matching images are rejected with a message pointing at this ADR.

Widening to Alpine (apk) and RHEL-like (dnf/yum) bases is straightforward — detect the package manager and branch in the overlay template — but adds an extra dimension of bases to test against. Deferred until there is concrete demand.

If you need an Alpine-flavored toolchain today, write a Debian-based `.ccr/Dockerfile` that installs the equivalent tools via apt.
