#!/bin/sh
# Default run — bypass-permissions. OpenCode has no separate gated mode,
# so this is the only entrypoint. The container is the safety boundary.
exec opencode "$@"
