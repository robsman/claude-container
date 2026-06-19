#!/usr/bin/env bash
# Bug class 2: caller ownership of FUSE-created files in shadow.
#
# Property: files created by a non-root caller through FUSE in the shadow
# tree are owned by the caller, not by the FUSE process (root). Without this,
# subsequent fchmod by the caller fails with EPERM at the kernel level,
# breaking GNU `install`, tar --preserve-permissions, etc.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe ownership)
cd "$ws"
"$RP" init >/dev/null
cont=$(rp_create_and_start ownership)

# Force a shadow-routed write as coder. .rp/shadow ships node_modules/ as
# shadowed by default; that's where the action goes.
out=$(container exec -u coder --workdir "$ws" "$cont" sh -c '
    set -x
    mkdir -p node_modules/_ownership_probe && cd node_modules/_ownership_probe
    touch f1
    mkdir d1
    ln -s f1 sym1
    install -m 0755 f1 f2          # the original failing pattern
' 2>&1) || fail "shadow create + install failed: $out"

# Read the uids back via FUSE listing.
out=$(container exec -u coder --workdir "$ws/node_modules/_ownership_probe" "$cont" \
    stat -c "%n %U" f1 d1 sym1 f2 2>&1)

while IFS= read -r line; do
    name=${line%% *}
    owner=${line##* }
    if [ "$owner" != "coder" ]; then
        fail "$name owned by '$owner', expected 'coder'"
    fi
done <<<"$out"

echo "OK test-caller-ownership"
