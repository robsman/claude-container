#!/usr/bin/env bash
# Property: the mount stack at /workspace is bind → tmpfs → fuse. With
# this layering, if rp-fuse ever goes away the tmpfs underneath surfaces
# (empty), NOT the raw host bind. ADR-0010 fail-closed invariant.
#
# We check the stack order STATICALLY rather than dynamically (kill
# rp-fuse → observe tmpfs) because the unified ENTRYPOINT supervises
# rp-fuse via tini: rp-fuse death = tini exit = container death, so
# there's no live container to observe post-unmount. The static order
# is the structural guarantee.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe failclosed)
cd "$ws"
"$RP" init >/dev/null
cont=$(rp_create_and_start failclosed)

# Wait for the fuse layer to appear.
for _ in $(seq 1 30); do
    container exec -u 0 "$cont" awk -v m="$ws" '$2==m && $3 ~ /^fuse/' /proc/mounts 2>/dev/null | grep -q . && break
    sleep 0.2
done

mounts=$(container exec -u 0 "$cont" awk -v m="$ws" '$2==m {print $3}' /proc/mounts 2>&1)
# /proc/mounts lists stacked mounts in mount-order (oldest first). For our
# init flow that means: <runtime-bind>, tmpfs, fuse — three lines, exactly.
count=$(echo "$mounts" | grep -c .)
[ "$count" -ge 3 ] || fail "expected >=3 mount lines at $ws, got $count: $mounts"

top=$(echo "$mounts" | tail -1)
mid=$(echo "$mounts" | tail -2 | head -1)

echo "$top" | grep -q '^fuse' || fail "topmost mount at $ws is not fuse, got '$top' (full: $mounts)"
[ "$mid" = "tmpfs" ] || fail "middle mount at $ws is not tmpfs, got '$mid' (full: $mounts)"

echo "OK test-fail-closed"
