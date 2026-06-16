#!/bin/bash -p
# /usr/local/bin/rp-init.sh
#
# Note the shebang: `bash -p`. By default bash auto-resets EUID to RUID at
# startup as a security measure when invoked with mismatched IDs. That kills
# the escalation done by /usr/local/bin/rp-init-bootstrap (setuid root) when
# we land in Docker Sandbox-style containers whose default user is non-root.
# The -p flag preserves the setuid escalation so the script runs as root.
# Apple Container's path is unaffected: there the container is created with
# --user 0 so RUID == EUID == 0 and -p is a no-op.
#
# Runs as PID 1 (root, CAP_SYS_ADMIN) at container start.
# Sets up the shadow boundary then launches rp-fuse.
#
# Boundary setup:
#   1. Move the host bind from /workspace-real to /var/lib/rp/backing
#      (root-only, mode 0700 — invisible to coder).
#   2. Overlay a tmpfs on /workspace-real so any container process looking at
#      that path sees an empty filesystem instead of host content.
#
# Layout after init:
#   /workspace-real           tmpfs overlay (empty, hiding the original bind)
#   /var/lib/rp/backing      bind to the host workspace (root-only)
#   /var/lib/rp/shadow       container-local writable store for shadowed paths
#   /workspace                FUSE mount that user/Claude sees
#
# Why this matters: see docs/adr/0005-shadow-as-security-boundary-via-drop-sudo.md.
# coder has no sudo and no capabilities, so it cannot umount the tmpfs or
# traverse /var/lib/rp to reach the host content directly.
#
# The container exits if rp-fuse exits.
set +e

REAL=/workspace-real
MNT=/workspace
SHADOW=/var/lib/rp/shadow

if [ ! -d "$REAL" ]; then
    echo "rp-init: $REAL does not exist; nothing to mount" >&2
    exec sleep infinity
fi

mkdir -p "$MNT" "$SHADOW"
chmod 0700 /var/lib/rp

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
    if cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null | sed 's/#.*//' \
            | grep -qE "(^|[[:space:]])${RP_USER}([[:space:]]|$)"; then
        echo "rp-init: configured RP_USER '$RP_USER' has a sudoers entry; refusing to launch (shadow boundary requires no sudo)" >&2
        exec sleep infinity
    fi
fi

# If a prior init left an FUSE mount around, drop it.
if mountpoint -q "$MNT"; then
    fusermount3 -u "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
fi

# Capture an fd on the host bind BEFORE we overmount it with tmpfs. The
# kernel resolves /proc/self/fd/N through the inode the fd already opens,
# not through path lookup, so rp-fuse can still reach the host content
# even after $REAL is hidden. This avoids bind/move syscalls — important
# for Docker Desktop, whose fakeowner FS refuses to be the source of any
# bind or move (see ADR-0010 status notes). Apple Container's virtiofs is
# also happy with this layout; one code path, two runtimes.
exec {BACKING_FD}<"$REAL" || {
    echo "rp-init: FAILED to open fd on $REAL" >&2
    exec sleep infinity
}
echo "rp-init: opened backing fd $BACKING_FD on $REAL" >&2

# Overlay tmpfs on $REAL so the container user can't reach the host bind
# directly. fd $BACKING_FD still references the original inode regardless.
if ! grep -qE " $REAL tmpfs " /proc/mounts; then
    mount -t tmpfs -o mode=755,uid=0,gid=0 none "$REAL" || {
        echo "rp-init: FAILED to overlay tmpfs on $REAL" >&2
        exec sleep infinity
    }
    echo "rp-init: hid $REAL with tmpfs" >&2
fi

RULES_FLAG=""
# Shadow rules live in the workspace at .rp/shadow. We reach them through
# the captured fd: /proc/self/fd/$BACKING_FD/.rp/shadow resolves via the
# fd's inode, not via path (the path is now tmpfs).
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

echo "rp-init: launching rp-fuse (backing via fd $BACKING_FD)" >&2
exec /usr/local/bin/rp-fuse \
    --backing-fd "$BACKING_FD" \
    --shadow "$SHADOW" \
    --mount "$MNT" \
    $RULES_FLAG \
    $CACHE_FLAG \
    $DEBUG_FLAG
