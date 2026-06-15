#!/usr/bin/env bash
# Installs sst/opencode. Runs as the configured container user during the
# rp overlay build. No sudo is available; the installer writes to ~/.local/bin.
set -euo pipefail

curl -fsSL https://opencode.ai/install | bash

# Smoke-check the installer landed the binary where we expect.
if [ ! -x "$HOME/.local/bin/opencode" ] && ! command -v opencode >/dev/null; then
    echo "opencode install: binary not on PATH after installer ran" >&2
    exit 1
fi
