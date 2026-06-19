#!/usr/bin/env bash
# Bug class 1: backing/shadow inode-namespace disjointness via FUSE.
#
# Property: stat + opendir of a backing-tree path and a shadow-tree path
# never alias in the kernel inode cache, even when their underlying inode
# numbers coincide. Pre-fix repro: backing strategies/ (ino 159) collided
# with shadow node_modules/@tsconfig/node10 (ino 159) and ls /strategies/
# returned ENOENT.
#
# Strategy: populate the shadow tree with enough files that low Ino numbers
# get reused, then ensure every backing entry remains openable + statable.
# This doesn't force the collision deterministically (inodes are FS-assigned)
# but it covers the realistic post-npm-install state.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe inode)
cd "$ws"
"$RP" init >/dev/null

# Backing-side seed: nest a few directories with files. Filenames are clearly
# project-source-like so they don't match any shadow rule.
mkdir -p src/lib/util src/lib/cache/strategies
echo "src content" > src/lib/util/u.ts
echo "src content" > src/lib/cache/cache.ts
echo "src content" > src/lib/cache/strategies/redis.ts
echo "src content" > src/lib/cache/strategies/local.ts

cont=$(rp_create_and_start inode)

# Populate shadow with many small files to drive low Ino numbers.
container exec -u coder --workdir "$ws" "$cont" sh -c '
    cd node_modules
    mkdir -p _inode_probe
    cd _inode_probe
    for i in $(seq 1 100); do
        mkdir -p "pkg$i"
        echo "x" > "pkg$i/index.js"
    done
' >/dev/null 2>&1 || fail "shadow populate failed"

# Now walk every backing file and require stat + opendir-where-applicable to
# match what host would see.
out=$(container exec -u coder --workdir "$ws" "$cont" sh -c '
    set +e
    fails=0
    for p in src/lib/util/u.ts src/lib/cache/cache.ts src/lib/cache/strategies/redis.ts src/lib/cache/strategies/local.ts; do
        if ! stat "$p" >/dev/null 2>&1; then
            echo "STAT-FAIL $p"
            fails=$((fails+1))
        fi
        if ! cat "$p" >/dev/null 2>&1; then
            echo "CAT-FAIL $p"
            fails=$((fails+1))
        fi
    done
    for d in src/lib src/lib/util src/lib/cache src/lib/cache/strategies; do
        if ! ls "$d" >/dev/null 2>&1; then
            echo "LS-FAIL $d"
            fails=$((fails+1))
        fi
    done
    echo "fails=$fails"
' 2>&1)

if ! grep -q 'fails=0' <<<"$out"; then
    fail "inode-disjoint property violated. Failures:\n$out"
fi

echo "OK test-inode-disjoint"
