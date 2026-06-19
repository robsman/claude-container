#!/usr/bin/env bash
# Shared helpers for rp-fuse integration tests. Sourced by every
# tests/integration/test-*.sh script.
#
# Tests run on the macOS host, talk to Apple Container, and exercise rp via
# the real wrapper. They build images, create containers, run assertions, and
# clean up. Each test is responsible for its own probe workspace + container.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RP="$REPO_DIR/rp"

# Probe state goes in /tmp so the host workspace doesn't get polluted.
TMPROOT=$(mktemp -d /tmp/rp-integration.XXXXXX)
trap "cleanup_probes" EXIT

PROBE_CONTAINERS=()
PROBE_WORKSPACES=()

mk_probe() {
    # Usage: mk_probe <slug>          -> echoes the probe workspace dir.
    # Returns the realpath so the value matches what `invocation_directory()`
    # reports inside Justfile recipes (macOS's /tmp is a symlink to
    # /private/tmp; just resolves it). Without realpath, assertions on
    # the bind-mount path inside the container would mismatch.
    local slug="$1"
    local ws="$TMPROOT/$slug"
    mkdir -p "$ws"
    ws=$(cd "$ws" && pwd -P)
    PROBE_WORKSPACES+=("$ws")
    echo "$ws"
}

remember_container() {
    PROBE_CONTAINERS+=("$1")
}

# Usage: rp_create_and_start <slug>
# Runs rp create + container start so subsequent `container exec` calls work.
# Registers the container for cleanup.
rp_create_and_start() {
    local slug="$1"
    local agent="${2:-claude-code}"
    "$RP" create "$slug" >/dev/null 2>&1 || fail "rp create $slug failed"
    local cont
    cont=$(container_name "$agent" "$slug")
    remember_container "$cont"
    container start "$cont" >/dev/null 2>&1 || fail "container start $cont failed"
    echo "$cont"
}

cleanup_probes() {
    local c
    for c in "${PROBE_CONTAINERS[@]:-}"; do
        [ -z "$c" ] && continue
        # --force lets delete kill a running container in one step. Without
        # it, `container delete` refuses on running containers and the next
        # test sees leftover state.
        container delete --force "$c" >/dev/null 2>&1 || true
    done
    rm -rf "$TMPROOT"
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    if [ "$1" != "$2" ]; then
        fail "expected '$2', got '$1' ($3)"
    fi
}

assert_contains() {
    if ! grep -qF "$2" <<<"$1"; then
        fail "expected substring '$2' in output: $1 ($3)"
    fi
}

# Resolve container name the way Justfile does: rp-<agent>-<basename>.
container_name() {
    local agent="$1"
    local basename="$2"
    echo "rp-${agent}-${basename}"
}
