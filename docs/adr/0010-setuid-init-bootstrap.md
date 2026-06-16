# Setuid Go wrapper for non-root rp-init bootstrap

`rp-init.sh` requires root: it mounts a tmpfs over `/workspace-real`, bind-mounts the host workspace into `/var/lib/rp/backing` (mode 0700 root), and execs `rp-fuse` as PID 1 with CAP_SYS_ADMIN. Apple Container's create flow does `container create --user 0 …` so init runs as root naturally; Docker Sandbox templates have no equivalent — they start their containers with a non-root `agent` user and offer no documented hook for a privileged pre-start step. ([Docker Sandbox kits docs](https://docs.docker.com/ai/sandboxes/customize/kits/): `commands.startup` runs as agent; `commands.install` runs once at kit setup, not per container start.)

We ship a small setuid-root Go binary, `rp-init-bootstrap`, baked into the rp-base image at `/usr/local/bin/rp-init-bootstrap` with mode `4755`. The Docker overlay uses it as `ENTRYPOINT`. When Docker starts the container as the agent user, the kernel's setuid handling escalates the bootstrap process to root before `main()` runs; the wrapper then `execve`s `/usr/local/bin/rp-init.sh`, which proceeds with the normal init sequence. Sessions continue to land as the agent via `docker exec -u <agent>`.

## Why Go (and not C)

The build pipeline already has a `golang:1.22-alpine` stage for `rp-fuse`. Adding a sibling stage for the bootstrap reuses that toolchain — one more `COPY rp-init-bootstrap/* . && go build` step, no new compiler in the image. The setuid concerns that historically motivated C (LD_PRELOAD injection caught by glibc's `secure_getenv`) don't apply: Go's static binaries don't dynamically link, so no `LD_*` interpretation happens. The Go runtime starts goroutines before `main()`, but the filesystem-bit setuid escalation happens in the kernel during execve — before any user-space code runs in the new process — so the multi-threaded runtime is irrelevant here. Cost is binary size (~2 MB statically-linked Go vs ~10 KB C); inconsequential inside a container layer.

## Scope kept deliberately tight

The wrapper:
- Hardcodes its target (`/usr/local/bin/rp-init.sh`). No path argument, no environment-driven target resolution.
- Drops argv. Whatever a caller passes is ignored, so a hostile invocation can't smuggle extra options into the script.
- Clears the inherited environment via `os.Clearenv()` and sets a small safe baseline (`PATH`, `HOME`, `TERM`). Forwards exactly three rp-controlled vars (`RP_DEBUG`, `RP_CACHE`, `RP_USER`) if they were present in the inherited env.

These constraints mean the audit surface is the wrapper's ~30 lines plus the existing rp-init.sh + rp-fuse content — the same content that already runs as root under Apple Container. The bootstrap doesn't widen what root-in-container can do; it just provides a second path to reach that state. We rejected sudo and capability-file grants because each is a more general escalation primitive (sudo grants execution of any command; capabilities like `cap_sys_admin` apply to all execs of a binary, not just the bootstrap flow).

The wrapper is no-op for Apple Container: that path stays on `container create --user 0` and never invokes the bootstrap. It only matters under Docker / Docker Sandbox / any runtime that defaults the container to a non-root user. If a future maintainer is tempted to extend the wrapper to accept arguments or call a different target, the comment in `main.go` forbids it and points back here.
