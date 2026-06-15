#!/usr/bin/env bash
# Workspace .rp/agents/<name>/manifest.yaml wins over the builtin. Partial
# override (dir present but no manifest.yaml) falls through to the builtin.
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$THIS/../.." && pwd)
RP_FUSE="$REPO/rp-fuse/rp-fuse-darwin-arm64"

if [ ! -x "$RP_FUSE" ]; then
    echo "SKIP test-profile-override: host binary missing (run 'rp build-host' first)" >&2
    exit 0
fi

WS=$(mktemp -d)
trap "rm -rf $WS" EXIT

# ── full override ─────────────────────────────────────────────────
mkdir -p "$WS/.rp/agents/claude-code"
cat > "$WS/.rp/agents/claude-code/manifest.yaml" <<EOF
name: claude-code
description: workspace override
EOF
cat > "$WS/.rp/agents/claude-code/install.sh" <<'EOF'
#!/bin/sh
true
EOF
cat > "$WS/.rp/agents/claude-code/run.sh" <<'EOF'
#!/bin/sh
exec claude "$@"
EOF
chmod 0755 "$WS/.rp/agents/claude-code"/*.sh

dir=$("$RP_FUSE" profile --workspace "$WS" --repo-dir "$REPO" --agent claude-code resolve)
source=$("$RP_FUSE" profile --workspace "$WS" --repo-dir "$REPO" --agent claude-code source)

if [ "$source" != "workspace" ]; then
    echo "FAIL: full override should win, got source=$source" >&2
    exit 1
fi
if [ "$dir" != "$WS/.rp/agents/claude-code" ]; then
    echo "FAIL: full override dir mismatch — got $dir" >&2
    exit 1
fi

# ── partial override (no manifest.yaml) — must fall through ───────
WS2=$(mktemp -d)
mkdir -p "$WS2/.rp/agents/claude-code"
cat > "$WS2/.rp/agents/claude-code/run.sh" <<'EOF'
#!/bin/sh
exec claude "$@"
EOF
chmod 0755 "$WS2/.rp/agents/claude-code/run.sh"

source2=$("$RP_FUSE" profile --workspace "$WS2" --repo-dir "$REPO" --agent claude-code source)
if [ "$source2" != "builtin" ]; then
    echo "FAIL: partial override (no manifest) should fall through, got source=$source2" >&2
    rm -rf "$WS2"
    exit 1
fi

# rp-fuse lint should WARN about the partial override.
lint=$("$RP_FUSE" lint --workspace "$WS2" --repo-dir "$REPO" 2>&1 || true)
if ! grep -q "partial workspace override" <<<"$lint"; then
    echo "FAIL: lint did not warn about partial override" >&2
    printf '%s\n' "$lint" >&2
    rm -rf "$WS2"
    exit 1
fi
rm -rf "$WS2"

echo "OK test-profile-override"
