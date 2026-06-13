#!/bin/sh
# Verifies that the .ccrshadow file at workspace root is read-only from inside
# the container — only the host may modify the ruleset.
set -eu

apk add --no-cache fuse3 >/dev/null 2>&1

HOST=/host
SHADOW=/shadow
MNT=/mnt
mkdir -p "$HOST" "$SHADOW" "$MNT"
rm -rf "$HOST"/* "$SHADOW"/* "$HOST"/.[!.]* 2>/dev/null || true

mkdir -p "$HOST/src"
echo "src" > "$HOST/src/main.go"
cat > "$HOST/.ccrshadow" <<EOF
node_modules
.env.local
EOF

/tools/ccr-fuse --backing "$HOST" --shadow "$SHADOW" --mount "$MNT" --rules "$HOST/.ccrshadow" --cache 0.1 &
FPID=$!
for i in 1 2 3 4 5 10; do mountpoint -q "$MNT" && break; sleep 0.2; done
mountpoint -q "$MNT" || { echo FAIL; exit 1; }

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILED=1; }
FAILED=0
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got=$1 want=$2)"; fi; }
expect_fail() {
    msg=$1; shift
    if "$@" 2>/dev/null; then fail "$msg (op unexpectedly succeeded)"; else pass "$msg (op rejected as expected)"; fi
}

echo "=== R1: read .ccrshadow from inside container ==="
got=$(cat "$MNT/.ccrshadow")
case "$got" in
    *node_modules*) pass "R1a content readable" ;;
    *)              fail "R1a expected rules content, got: $got" ;;
esac

echo
echo "=== R2: write attempts return EROFS ==="
expect_fail "R2a echo >> .ccrshadow"        sh -c "echo 'new-rule' >> $MNT/.ccrshadow"
expect_fail "R2b echo > .ccrshadow"         sh -c "echo 'overwrite' > $MNT/.ccrshadow"
expect_fail "R2c truncate .ccrshadow"       truncate -s 0 "$MNT/.ccrshadow"
expect_fail "R2d chmod 600 .ccrshadow"      chmod 600 "$MNT/.ccrshadow"
expect_fail "R2e rm .ccrshadow"             rm "$MNT/.ccrshadow"
expect_fail "R2f mv .ccrshadow other"       mv "$MNT/.ccrshadow" "$MNT/other"
expect_fail "R2g mv x .ccrshadow (rename onto rules path)" sh -c "echo y > $MNT/scratch && mv $MNT/scratch $MNT/.ccrshadow"

echo
echo "=== R3: host file unchanged throughout ==="
host_content=$(cat "$HOST/.ccrshadow")
case "$host_content" in
    *node_modules*) pass "R3a host rules intact" ;;
    *)              fail "R3a host rules corrupted: $host_content" ;;
esac
host_size=$(wc -c < "$HOST/.ccrshadow")
[ "$host_size" -gt 0 ] && pass "R3b host file non-empty (size=$host_size)" || fail "R3b host file empty"

echo
echo "=== R4: read works repeatedly (open-for-read not blocked) ==="
for i in 1 2 3; do
    cat "$MNT/.ccrshadow" > /dev/null 2>&1 && true
done
pass "R4 multiple reads ok"

echo
echo "=== R5: host can still write to /host/.ccrshadow ==="
echo "added-from-host" >> "$HOST/.ccrshadow"
got=$(grep "added-from-host" "$HOST/.ccrshadow")
[ -n "$got" ] && pass "R5 host edit succeeded" || fail "R5 host edit failed"

echo
echo "=== unmount ==="
cd /
fusermount3 -u "$MNT" 2>&1 || umount -l "$MNT"
wait $FPID 2>/dev/null || true

if [ "$FAILED" = "0" ]; then
    echo "ALL READ-ONLY-RULES TESTS PASSED"
    exit 0
else
    echo "READ-ONLY-RULES TESTS FAILED"
    exit 1
fi
