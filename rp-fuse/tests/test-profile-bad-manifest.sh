#!/usr/bin/env bash
# Manifest violations: unknown key, non-absolute files[].dst, non-POSIX env
# name. Each should be rejected by ParseProfileManifest (exit 1 with a
# helpful error message).
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$THIS/../.." && pwd)
RP_FUSE="$REPO/rp-fuse/rp-fuse-darwin-arm64"

if [ ! -x "$RP_FUSE" ]; then
    echo "SKIP test-profile-bad-manifest: host binary missing" >&2
    exit 0
fi

WS=$(mktemp -d)
trap "rm -rf $WS" EXIT

run_case() {
    local label=$1 manifest=$2 expected_phrase=$3
    rm -rf "$WS/.rp/agents/probe"
    mkdir -p "$WS/.rp/agents/probe"
    printf '%s' "$manifest" > "$WS/.rp/agents/probe/manifest.yaml"

    set +e
    out=$("$RP_FUSE" profile --workspace "$WS" --repo-dir "$REPO" --agent probe validate 2>&1)
    ec=$?
    set -e

    if [ "$ec" -eq 0 ]; then
        echo "FAIL [$label]: bad manifest accepted" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    if ! grep -qF "$expected_phrase" <<<"$out"; then
        echo "FAIL [$label]: error message did not contain '$expected_phrase'" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
}

run_case "unknown-key" \
"name: probe
mystery_field: 42
" \
"mystery_field"

run_case "lowercase-env" \
"name: probe
env: [api_key]
" \
"POSIX env var"

run_case "non-absolute-dst" \
"name: probe
files:
  - src: a.txt
    dst: home/coder/x
" \
"must be absolute"

run_case "absolute-src" \
"name: probe
files:
  - src: /etc/passwd
    dst: /home/coder/x
" \
"relative to the profile dir"

run_case "dotdot-src" \
"name: probe
files:
  - src: ../secret
    dst: /home/coder/x
" \
".."

run_case "missing-name" \
"description: nameless
" \
"name is required"

run_case "bad-name-chars" \
"name: Bad_Name
" \
"invalid character"

run_case "absolute-entrypoint" \
"name: probe
entrypoints:
  run: /usr/local/bin/claude
" \
"relative to the profile dir"

echo "OK test-profile-bad-manifest"
