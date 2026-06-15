#!/usr/bin/env bash
# Smoke test for the opencode workspace example. Verifies the profile loader
# picks up the workspace override and the manifest passes validation. Does
# NOT build a container or run the installer — that requires `container` +
# network access and is left to the user.
set -euo pipefail

THIS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$THIS_DIR/../.." && pwd)
RP_FUSE="$REPO_DIR/rp-fuse/rp-fuse-darwin-arm64"

if [ ! -x "$RP_FUSE" ]; then
    echo "FAIL: rp-fuse host binary missing at $RP_FUSE" >&2
    echo "      Run 'rp build-host' from the repo root first." >&2
    exit 1
fi

resolved=$("$RP_FUSE" profile --workspace "$THIS_DIR" --repo-dir "$REPO_DIR" --agent opencode resolve)
source=$("$RP_FUSE" profile --workspace "$THIS_DIR" --repo-dir "$REPO_DIR" --agent opencode source)

if [ "$source" != "workspace" ]; then
    echo "FAIL: expected workspace override to win, got source=$source (resolved=$resolved)" >&2
    exit 1
fi

expected_dir="$THIS_DIR/.rp/agents/opencode"
if [ "$resolved" != "$expected_dir" ]; then
    echo "FAIL: resolver dir mismatch" >&2
    echo "  expected: $expected_dir" >&2
    echo "  got:      $resolved" >&2
    exit 1
fi

# Manifest validates cleanly?
"$RP_FUSE" profile --workspace "$THIS_DIR" --repo-dir "$REPO_DIR" --agent opencode validate

# rp lint over the example workspace surfaces the profile + the WARN for
# the missing run-gated.sh + the WARN for the missing login.sh.
lint_out=$("$RP_FUSE" lint --workspace "$THIS_DIR" --repo-dir "$REPO_DIR" 2>&1 || true)

if ! grep -q "agent profile opencode: OK (workspace)" <<<"$lint_out"; then
    echo "FAIL: rp lint did not report profile as workspace-sourced" >&2
    printf '%s\n' "$lint_out" >&2
    exit 1
fi

if ! grep -q "WARN entrypoint run_gated" <<<"$lint_out"; then
    echo "FAIL: rp lint did not warn about missing run-gated.sh" >&2
    printf '%s\n' "$lint_out" >&2
    exit 1
fi

if ! grep -q "WARN entrypoint login" <<<"$lint_out"; then
    echo "FAIL: rp lint did not warn about missing login.sh" >&2
    printf '%s\n' "$lint_out" >&2
    exit 1
fi

echo "OK: opencode workspace example resolves + validates"
