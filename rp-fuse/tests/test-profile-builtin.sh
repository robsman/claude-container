#!/usr/bin/env bash
# Workspace with no override; resolver picks the builtin claude-code profile.
# Runs against the host rp-fuse binary — no container required.
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$THIS/../.." && pwd)
RP_FUSE="$REPO/rp-fuse/rp-fuse-darwin-arm64"

if [ ! -x "$RP_FUSE" ]; then
    echo "SKIP test-profile-builtin: host binary missing (run 'rp build-host' first)" >&2
    exit 0
fi

WS=$(mktemp -d)
trap "rm -rf $WS" EXIT

# Workspace has nothing — should fall through to the builtin.
dir=$("$RP_FUSE" profile --workspace "$WS" --repo-dir "$REPO" --agent claude-code resolve)
source=$("$RP_FUSE" profile --workspace "$WS" --repo-dir "$REPO" --agent claude-code source)

if [ "$source" != "builtin" ]; then
    echo "FAIL: expected source=builtin, got $source" >&2
    exit 1
fi

if [ "$dir" != "$REPO/agent.profiles/claude-code" ]; then
    echo "FAIL: expected dir under agent.profiles/claude-code/, got $dir" >&2
    exit 1
fi

# `rp-fuse profile validate` parses + validates without exit 1.
"$RP_FUSE" profile --workspace "$WS" --repo-dir "$REPO" --agent claude-code validate

echo "OK test-profile-builtin"
