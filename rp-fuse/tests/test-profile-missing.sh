#!/usr/bin/env bash
# Requesting a profile that exists nowhere — resolver and lint must both
# error with exit 1 + a message naming the missing profile.
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$THIS/../.." && pwd)
RP_FUSE="$REPO/rp-fuse/rp-fuse-darwin-arm64"

if [ ! -x "$RP_FUSE" ]; then
    echo "SKIP test-profile-missing: host binary missing (run 'rp build-host' first)" >&2
    exit 0
fi

WS=$(mktemp -d)
trap "rm -rf $WS" EXIT

# Direct resolve: exit 1, mention "no profile".
set +e
out=$("$RP_FUSE" profile --workspace "$WS" --repo-dir "$REPO" --agent does-not-exist resolve 2>&1)
ec=$?
set -e
if [ "$ec" -eq 0 ]; then
    echo "FAIL: resolve of missing profile should exit non-zero" >&2
    exit 1
fi
if ! grep -q 'no profile "does-not-exist"' <<<"$out"; then
    echo "FAIL: resolver error did not mention the missing profile name" >&2
    printf '%s\n' "$out" >&2
    exit 1
fi

# Lint via .rp/config.yaml `agent:` field — same outcome.
mkdir -p "$WS/.rp"
echo "agent: does-not-exist" > "$WS/.rp/config.yaml"

set +e
out=$("$RP_FUSE" lint --workspace "$WS" --repo-dir "$REPO" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 0 ]; then
    echo "FAIL: lint should exit non-zero when config names a nonexistent profile" >&2
    exit 1
fi
if ! grep -q 'no profile' <<<"$out"; then
    echo "FAIL: lint error did not mention the missing profile" >&2
    printf '%s\n' "$out" >&2
    exit 1
fi

echo "OK test-profile-missing"
