#!/usr/bin/env bash
# Property: .rp/shadow honours gitignore negation. A `!path` rule re-exposes
# a previously-shadowed subtree, routing reads/writes to the host bind
# instead of the per-container shadow store.
#
# Pattern under test (gitignore-compatible — see ADR-0011):
#   node_modules/**
#   !node_modules/important
#   !node_modules/important/**
#
# This shadows everything under node_modules EXCEPT the `important` subtree.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe shadowneg)
cd "$ws"
"$RP" init >/dev/null

# Replace the default .rp/shadow with negation-bearing rules.
#
# Pattern note: we use `node_modules/*` + `node_modules/**/*` (rather than
# `node_modules/**`) so the PARENT `node_modules` is not itself matched —
# go-gitignore treats `dir/**` as also matching `dir`, which makes drilling
# into a re-exposed subtree impossible (Lookup of node_modules would route
# to shadow before the FUSE can examine children). Matching children only
# leaves the parent visible.
cat > .rp/shadow <<'EOF'
node_modules/*
node_modules/**/*
!node_modules/important
!node_modules/important/**
EOF

# Seed host content under both the to-be-shadowed and the re-exposed paths.
mkdir -p node_modules/normal node_modules/important
echo "from-host-normal" > node_modules/normal/host.txt
echo "from-host-important" > node_modules/important/keep.txt

cont=$(rp_create_and_start shadowneg)

# Container view:
#   node_modules/important/keep.txt MUST be the host content (re-exposed).
got=$(container exec -u coder --workdir "$ws" "$cont" cat node_modules/important/keep.txt 2>&1)
assert_eq "$got" "from-host-important" "negated path reads host content"

#   node_modules/normal/host.txt MUST NOT be visible (parent shadowed).
out=$(container exec -u coder --workdir "$ws" "$cont" sh -c 'cat node_modules/normal/host.txt 2>&1; echo EXIT=$?')
echo "$out" | grep -q 'EXIT=0' && fail "shadowed file unexpectedly readable: $out"

# Container write to the re-exposed subtree must land on the HOST bind
# (no shadow indirection).
container exec -u coder --workdir "$ws" "$cont" sh -c 'echo from-container > node_modules/important/wrote.txt' \
    || fail "writing to re-exposed path failed"
[ "$(cat node_modules/important/wrote.txt)" = "from-container" ] \
    || fail "host did not receive write to re-exposed path"

# Container write to a shadowed sibling must land in the shadow store
# (host directory should NOT see it).
container exec -u coder --workdir "$ws" "$cont" sh -c 'mkdir -p node_modules/other && echo shadowed > node_modules/other/file.txt' \
    || fail "shadow-side write failed"
[ ! -e "$ws/node_modules/other/file.txt" ] \
    || fail "shadow-side write leaked to host"

echo "OK test-shadow-negation"
