#!/usr/bin/env bash
# Property: the rp init chain delivers a FUSE mount at the discovered
# workspace, owned by uid 0 — i.e. the unified ENTRYPOINT escalated to
# root and used CAP_SYS_ADMIN to mount.
#
# PID 1 itself is tini (uid 1000) by design; the escalation happens
# downstream in the bootstrap. We assert the post-condition (a root-owned
# fuse mount) rather than the intermediate PID identity.
#
# Regression guard: future changes that strip the setuid bit, lose
# CAP_SYS_ADMIN from the bounding set, or break the escalation chain
# will leave /workspace without a fuse mount, tripping this assertion.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe pid1-root)
cd "$ws"
"$RP" init >/dev/null
cont=$(rp_create_and_start pid1-root)

# Wait up to 6s for rp-fuse to come up (init flow is bootstrap → init.sh →
# exec rp-fuse, with a few mount syscalls in between).
for _ in $(seq 1 30); do
    if container exec -u 0 "$cont" awk -v m="$ws" '$2==m && $3 ~ /^fuse/' /proc/mounts 2>/dev/null | grep -q .; then
        break
    fi
    sleep 0.2
done

line=$(container exec -u 0 "$cont" awk -v m="$ws" '$2==m && $3 ~ /^fuse/' /proc/mounts 2>&1 || true)
[ -n "$line" ] || fail "no fuse mount at $ws after 6s"

# Mount-line uid: fuse mounts include user_id=<owner>. Root mounting
# requires CAP_SYS_ADMIN (kernel side) — so user_id=0 implies the chain
# escalated successfully.
grep -q 'user_id=0' <<<"$line" || fail "fuse mount not owned by root: $line"

echo "OK test-pid1-root"
