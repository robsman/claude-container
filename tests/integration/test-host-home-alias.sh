#!/usr/bin/env bash
# Property: host_path_aliases creates per-subpath symlinks so host-
# absolute references inside settings.json / hooks / IDE config
# resolve inside the container. We test with ~/.claude — a stable
# subpath that doesn't collide with workspace binds.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe homealias)
cd "$ws"
"$RP" init >/dev/null
cat >> .rp/config.yaml <<EOF

host_path_aliases:
  - ~/.claude
EOF

cont=$(rp_create_and_start homealias)

# Expected: $HOME/.claude (host path) is a symlink → /home/coder/.claude
host_claude="$HOME/.claude"
container_target=/home/coder/.claude

# (1) symlink at host_path
out=$(container exec -u 0 "$cont" sh -c "test -L '$host_claude' && readlink '$host_claude'" 2>&1)
assert_eq "$out" "$container_target" "symlink at $host_claude points at $container_target"

# (2) traversal works: write through host_claude, read via container_target.
container exec -u coder "$cont" sh -c "echo via-host > '$host_claude/marker.txt'" \
    || fail "could not write through host-path alias"
out=$(container exec -u coder "$cont" cat "$container_target/marker.txt" 2>&1)
assert_eq "$out" "via-host" "write through alias visible at canonical path"

# (3) idempotency across restart.
container stop "$cont" >/dev/null 2>&1 || true
container start "$cont" >/dev/null 2>&1 || fail "restart failed"
out=$(container exec -u 0 "$cont" sh -c "readlink '$host_claude'" 2>&1)
assert_eq "$out" "$container_target" "symlink survives restart"

echo "OK test-host-home-alias"
