#!/usr/bin/env bash
# Profile manifest's env: allow-list drives `container create -e` flags via
# scripts/resolve-create-args.sh. Only declared names are forwarded.
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$THIS/../.." && pwd)
RP_FUSE="$REPO/rp-fuse/rp-fuse-darwin-arm64"

if [ ! -x "$RP_FUSE" ]; then
    echo "SKIP test-profile-env-forwarding: host binary missing" >&2
    exit 0
fi

WS=$(mktemp -d)
trap "rm -rf $WS" EXIT

# Build a workspace-local profile that declares two env vars.
mkdir -p "$WS/.rp/agents/probe"
cat > "$WS/.rp/agents/probe/manifest.yaml" <<EOF
name: probe
env: [FOO, BAR]
EOF
cat > "$WS/.rp/agents/probe/install.sh" <<'EOF'
#!/bin/sh
true
EOF
cat > "$WS/.rp/agents/probe/run.sh" <<'EOF'
#!/bin/sh
true
EOF
chmod 0755 "$WS/.rp/agents/probe"/*.sh
mkdir -p "$WS/.rp"
echo "agent: probe" > "$WS/.rp/config.yaml"

# Check the env field round-trips through the field accessor (newline-separated).
env_lines=$("$RP_FUSE" profile --workspace "$WS" --repo-dir "$REPO" --config "$WS/.rp/config.yaml" field env)
expected="FOO
BAR"
if [ "$env_lines" != "$expected" ]; then
    echo "FAIL: env field mismatch" >&2
    printf 'got: %s\nwant: %s\n' "$env_lines" "$expected" >&2
    exit 1
fi

# Drive resolve-create-args.sh end-to-end: with FOO+BAR+BAZ in the host env,
# CONTAINER_ENV should pick up FOO and BAR but not BAZ.
unset FOO BAR BAZ 2>/dev/null || true
export FOO=1 BAR=2 BAZ=3
out=$(FOO=1 BAR=2 BAZ=3 "$REPO/scripts/resolve-create-args.sh" "$WS")
eval "$out"
if ! grep -q -- "-e FOO" <<<"$CONTAINER_ENV"; then
    echo "FAIL: CONTAINER_ENV missing -e FOO ($CONTAINER_ENV)" >&2
    exit 1
fi
if ! grep -q -- "-e BAR" <<<"$CONTAINER_ENV"; then
    echo "FAIL: CONTAINER_ENV missing -e BAR ($CONTAINER_ENV)" >&2
    exit 1
fi
if grep -q -- "-e BAZ" <<<"$CONTAINER_ENV"; then
    echo "FAIL: CONTAINER_ENV unexpectedly includes -e BAZ" >&2
    exit 1
fi

echo "OK test-profile-env-forwarding"
