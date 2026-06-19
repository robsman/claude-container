#!/bin/bash -p
# /usr/local/bin/rp-init.sh
#
# Note the shebang: `bash -p`. By default bash auto-resets EUID to RUID at
# startup as a security measure when invoked with mismatched IDs. That kills
# the escalation done by /usr/local/bin/rp-init-bootstrap (setuid root) when
# we land in containers whose default user is non-root. The -p flag
# preserves the setuid escalation so the script runs as root regardless of
# the runtime's default-user policy.
#
# Runs as PID 1 (root, CAP_SYS_ADMIN) at container start.
# Sets up the shadow boundary then launches rp-fuse.
#
# Mount layout at /workspace (the host bind):
#   1. Unwind any prior stacked mounts so we rebuild from a known state.
#   2. Capture an fd on /workspace BEFORE any overmount. The kernel resolves
#      /proc/self/fd/N through the inode the fd already opens, so rp-fuse
#      reaches the original host bind via /proc/self/fd/N regardless of
#      whatever sits on top of /workspace later.
#   3. Mount tmpfs on /workspace. This is the fail-closed backstop: if any
#      validation below fails, or rp-fuse later fails / never mounts, the
#      user sees the empty tmpfs, not the raw host content underneath.
#   4. Validate the configured user. From here on `sleep infinity` is safe:
#      tmpfs covers the bind, so an operator-error-induced sleep leaves the
#      container debuggable without exposing the host workspace.
#   5. Mount rp-fuse on /workspace, overlaying the tmpfs.
#
# Stack at /workspace after init: bind (fakeowner / virtiofs) → tmpfs → FUSE.
# Container user sees FUSE. If FUSE goes away, tmpfs reappears (empty), not
# the bind.
#
# Failure semantics:
#   * Anything that runs BEFORE the tmpfs cover (mkdir of shadow store,
#     unwind, fd capture, tmpfs itself) exits non-zero. The container dies
#     rather than sleep with the raw bind exposed.
#   * Anything that runs AFTER the tmpfs cover (user validation, rp-fuse
#     exec) uses `sleep infinity` so the operator can `docker exec` to
#     debug. tmpfs hides the bind for the duration of that sleep.
#
# Why this matters: see docs/adr/0005-shadow-as-security-boundary-via-drop-sudo.md
# and docs/adr/0010-setuid-init-bootstrap.md (FUSE-on-bind layout section).
#
# The container exits if rp-fuse exits.
set +e

SHADOW=/var/lib/rp/shadow

# Diagnostic mode. RP_DIAGNOSE=1 turns pre-tmpfs failures into `sleep
# infinity` (with full state dumped to the log) instead of `exit 1`.
# Use when the runtime swallows stdout/stderr (e.g. Docker Sandbox) and you
# need to `<runtime> exec` into the still-alive container to read the log.
# DO NOT leave this on in production — `sleep infinity` with the raw bind
# exposed at /workspace is fail-open.
#
# Log location: $RP_LOG_DIR/rp-init.log if RP_LOG_DIR is set + writable,
# else /tmp/rp-init.log (container-local, dies with container). Bind-mount
# a host dir at e.g. /tmp/rp-diag and set RP_LOG_DIR=/tmp/rp-diag to make
# the log persist even after the container exits.
if [ -n "${RP_LOG_DIR:-}" ] && [ -d "$RP_LOG_DIR" ] && [ -w "$RP_LOG_DIR" ]; then
    DIAG_LOG="$RP_LOG_DIR/rp-init.log"
else
    DIAG_LOG=/tmp/rp-init.log
fi
# Heartbeat write so users diagnosing Sandbox-like environments can confirm
# the script even started. Cheap (3 lines, runs always).
{
    echo "=== rp-init started $(date -Iseconds 2>/dev/null || date) ==="
    echo "rp-init: pid=$$ ppid=$PPID uid=$(id -u) euid=$(id -u 2>/dev/null) DIAG=${RP_DIAGNOSE:-0} LOG_DIR=${RP_LOG_DIR:-}"
} > "$DIAG_LOG" 2>/dev/null || true
diag_init() {
    : > "$DIAG_LOG"
    {
        echo "=== rp-init diagnostic dump ($(date -Iseconds 2>/dev/null || date)) ==="
        echo
        echo "--- /proc/1/status (Uid/Gid/Caps) ---"
        grep -E '^(Uid|Gid|CapInh|CapPrm|CapEff|CapBnd|CapAmb):' /proc/1/status
        echo
        echo "--- env (rp-relevant) ---"
        env | grep -E '^(RP_|HOME|PATH|USER|UID|GID)' | sort
        echo
        echo "--- /proc/mounts ---"
        cat /proc/mounts
        echo
    } >> "$DIAG_LOG" 2>&1
}
die() {
    local reason=$1
    echo "rp-init: FAILED ($reason)" >&2
    if [ "${RP_DIAGNOSE:-}" = "1" ]; then
        diag_init
        {
            echo "--- failure ---"
            echo "$reason"
        } >> "$DIAG_LOG"
        echo "rp-init: diagnostic dumped to $DIAG_LOG; sleeping for inspection (RP_DIAGNOSE=1)" >&2
        exec sleep infinity
    fi
    exit 1
}

# --- Workspace discovery -------------------------------------------------
#
# Two sources, evaluated in order:
#   1. $RP_WORKSPACE if set and is a directory. The rp wrapper sets this
#      to the host path of the workspace (1:1 bind, so the same path
#      inside and outside the container). Sandbox-style templates set it
#      explicitly in their kit config.
#   2. Scan /proc/mounts for virtiofs / 9p / fakeowner mounts whose
#      target is a directory containing .rp/. First match wins. This is
#      the fallback path for runtimes that don't pass RP_WORKSPACE — e.g.
#      a user running `docker run -v /path:/path -e RP_WORKSPACE=/path` is
#      the env path; without the -e flag, scan picks /path up via virtiofs.
#
# Multi-workspace (Phase 2) extends this to return a LIST; today both
# paths return a single workspace.

discover_workspace() {
    if [ -n "${RP_WORKSPACE:-}" ]; then
        if [ -d "$RP_WORKSPACE" ]; then
            echo "$RP_WORKSPACE"
            return 0
        else
            echo "rp-init: RP_WORKSPACE=$RP_WORKSPACE is not a directory" >&2
            return 1
        fi
    fi
    # Scan for first virtiofs / 9p / fuse.fakeowner mount that is a
    # directory and contains .rp/. Warn if there are extras (Phase 2 work).
    local first=""
    local extras=()
    while read -r _ target fstype _; do
        # Host-share fstypes we accept as workspace candidates:
        #   virtiofs        - Apple Container, Docker Sandbox
        #   9p              - some QEMU/virt setups
        #   fakeowner       - Docker Desktop for macOS (fstype as reported in
        #                     /proc/mounts; the "fuse." prefix is not used)
        #   fuse.fakeowner  - older Docker Desktop variants
        case "$fstype" in virtiofs|9p|fakeowner|fuse.fakeowner) ;; *) continue ;; esac
        [ -d "$target" ] || continue
        [ -d "$target/.rp" ] || continue
        if [ -z "$first" ]; then
            first=$target
        else
            extras+=("$target")
        fi
    done < /proc/mounts
    if [ -n "$first" ]; then
        if [ "${#extras[@]}" -gt 0 ]; then
            echo "rp-init: WARN multiple rp-marked workspaces found; using $first; ignoring: ${extras[*]}" >&2
            echo "        (multi-workspace FUSE is not implemented yet; set RP_WORKSPACE to pick deterministically)" >&2
        fi
        echo "$first"
        return 0
    fi
    return 1
}

MNT=$(discover_workspace) || die "no rp workspace found; set RP_WORKSPACE or bind a workspace dir whose root has .rp/ (virtiofs/9p/fakeowner mount)"
echo "rp-init: workspace = $MNT" >&2

# --- Pre-cover phase: failures here exit (or sleep under RP_DIAGNOSE). ---

[ -d "$MNT" ] || die "$MNT does not exist"

mkdir -p "$SHADOW" || die "cannot mkdir $SHADOW"
chmod 0700 /var/lib/rp

# Unwind anything a prior init left stacked on $MNT (FUSE, tmpfs, or
# both) so this init rebuilds from a known state. The runtime bind is
# the bottom of the stack — leave it (umounting it would lose the host
# workspace content). We detect "bottom" as "exactly one mount line for
# $MNT in /proc/mounts" — that's the bind itself; anything more is ours
# to tear down.
mount_count() { awk -v m="$1" '$2==m' /proc/mounts | wc -l; }
unwind_attempts=0
while [ "$(mount_count "$MNT")" -gt 1 ]; do
    unwind_attempts=$((unwind_attempts + 1))
    [ "$unwind_attempts" -le 8 ] || die "$MNT still has stacked mounts after 8 umount attempts"
    fusermount3 -u "$MNT" 2>/dev/null \
        || umount "$MNT" 2>/dev/null \
        || umount -l "$MNT" 2>/dev/null \
        || die "cannot unwind stacked mount on $MNT"
done

# Capture an fd on the host bind BEFORE we overmount it. The kernel
# resolves /proc/self/fd/N through the fd's inode, not via path lookup,
# so rp-fuse can still reach the host content after we stack tmpfs +
# FUSE on top. This avoids bind/move syscalls — important for Docker
# Desktop, whose fakeowner FS refuses to be the source of any bind or
# move (see ADR-0010 status notes).
exec {BACKING_FD}<"$MNT" || {
    die "FAILED to open fd on $MNT"
}
echo "rp-init: opened backing fd $BACKING_FD on $MNT" >&2

# Some Sandbox-style base images (notably docker/sandbox-templates:shell-docker)
# ship without /dev/fuse but grant CAP_MKNOD. The kernel fuse driver
# auto-loads on first open of the device, so creating it on demand is
# safe. Skip silently if it's already there OR if we can't create it
# (rp-fuse open will then fail later with a clear errno).
if [ ! -e /dev/fuse ]; then
    if mknod /dev/fuse c 10 229 2>/dev/null && chmod 0666 /dev/fuse 2>/dev/null; then
        echo "rp-init: created missing /dev/fuse (c 10 229)" >&2
    else
        echo "rp-init: WARN /dev/fuse missing and could not be created" >&2
    fi
fi

# Stack tmpfs on $MNT as the fail-closed cover. From this line onward,
# any non-tmpfs failure can sleep without exposing the bind.
mount -t tmpfs -o mode=755,uid=0,gid=0 none "$MNT" || {
    die "FAILED to overlay tmpfs on $MNT; cannot guarantee fail-closed"
}
echo "rp-init: overlaid tmpfs on $MNT (fail-closed cover in place)" >&2

# --- Post-cover phase: failures here sleep so the container is debuggable. -

# Re-assert the shadow-boundary invariants (ADR-0005 / ADR-0008 invariant 3):
# the configured container user must exist, have uid != 0, and not be listed
# in any sudoers file. The overlay build enforces the same checks; this is
# belt-and-braces against (a) a build path that slips a privileged user
# through, (b) a sudoers edit that landed between build and start.
if [ -n "${RP_USER:-}" ]; then
    if ! id -u "$RP_USER" >/dev/null 2>&1; then
        echo "rp-init: configured RP_USER '$RP_USER' does not exist in image; refusing to launch" >&2
        exec sleep infinity
    fi
    if [ "$(id -u "$RP_USER")" = "0" ]; then
        echo "rp-init: configured RP_USER '$RP_USER' has uid 0; refusing to launch (shadow boundary requires uid != 0)" >&2
        exec sleep infinity
    fi
    # Strip comments before matching so a legitimate base-image comment
    # like '# Ditto for GPG agent' doesn't false-positive when the
    # configured user happens to be named the same as a word in comments.
    #
    # Bypass with RP_ALLOW_SUDO=1: required for Docker Sandbox, whose
    # base image mandates passwordless sudo for the agent user. Under
    # Sandbox the in-container shadow boundary is necessarily weaker
    # (agent can `sudo umount` the FUSE layer); Sandbox's outer VM
    # isolation is the actual security boundary in that environment.
    if [ "${RP_ALLOW_SUDO:-}" != "1" ] \
            && cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null | sed 's/#.*//' \
            | grep -qE "(^|[[:space:]])${RP_USER}([[:space:]]|$)"; then
        echo "rp-init: configured RP_USER '$RP_USER' has a sudoers entry; refusing to launch (shadow boundary requires no sudo; set RP_ALLOW_SUDO=1 to bypass)" >&2
        exec sleep infinity
    fi
fi

RULES_FLAG=""
# Shadow rules live in the workspace at .rp/shadow. We reach them through
# the captured fd: /proc/self/fd/$BACKING_FD/.rp/shadow resolves via the
# fd's inode, not via path (the path is now tmpfs + FUSE).
RULES="/proc/self/fd/$BACKING_FD/.rp/shadow"
if [ -f "$RULES" ]; then
    RULES_FLAG="--rules $RULES"
    echo "rp-init: using rules from .rp/shadow" >&2
else
    echo "rp-init: no .rp/shadow in workspace; pure passthrough" >&2
fi

CACHE_FLAG=""
if [ -n "${RP_CACHE:-}" ]; then
    CACHE_FLAG="--cache $RP_CACHE"
    echo "rp-init: fuse cache TTL = ${RP_CACHE}s (from RP_CACHE)" >&2
fi

DEBUG_FLAG=""
if [ "${RP_DEBUG:-}" = "1" ]; then
    DEBUG_FLAG="--debug"
    echo "rp-init: FUSE debug logging enabled (RP_DEBUG=1)" >&2
fi

echo "rp-init: launching rp-fuse (backing via fd $BACKING_FD, FUSE over tmpfs over bind)" >&2
exec /usr/local/bin/rp-fuse \
    --backing-fd "$BACKING_FD" \
    --shadow "$SHADOW" \
    --mount "$MNT" \
    $RULES_FLAG \
    $CACHE_FLAG \
    $DEBUG_FLAG
