#!/usr/bin/env bash
# Property: rp injects /etc/hosts entries inside the container for the
# always-on `host.containers.internal` alias and any user-declared
# entries in `.rp/config.yaml`'s `host_aliases:` block.
#
# - Default-only workspace: host.containers.internal resolves to the
#   container's default-route gateway (the host).
# - User-declared scalar alias: same IP, different name.
# - User-declared fixed-IP alias: maps to the supplied IP exactly.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe hosts)
cd "$ws"
"$RP" init >/dev/null
cat >> .rp/config.yaml <<EOF

host_aliases:
  - mac.local
  - name: pinned.example.com
    ip: 10.99.0.42
EOF

cont=$(rp_create_and_start hosts)

# Read /etc/hosts. The rp-managed entries are tagged with the
# `# rp-host-alias` trailing comment.
hosts=$(container exec -u 0 "$cont" grep '# rp-host-alias' /etc/hosts 2>&1 || true)
[ -n "$hosts" ] || fail "no rp-host-alias entries in /etc/hosts:\n$(container exec -u 0 "$cont" cat /etc/hosts)"

# Required: host.containers.internal must be present.
grep -q 'host\.containers\.internal' <<<"$hosts" \
    || fail "host.containers.internal missing from /etc/hosts:\n$hosts"

# User-declared scalar mac.local — must share IP with host.containers.internal
# (both resolve to the gateway).
gw_ip=$(grep 'host\.containers\.internal' <<<"$hosts" | awk '{print $1}')
mac_ip=$(grep 'mac\.local' <<<"$hosts" | awk '{print $1}')
[ "$mac_ip" = "$gw_ip" ] \
    || fail "mac.local IP ($mac_ip) != host.containers.internal IP ($gw_ip):\n$hosts"

# User-declared fixed IP — must match exactly.
pin_ip=$(grep 'pinned\.example\.com' <<<"$hosts" | awk '{print $1}')
[ "$pin_ip" = "10.99.0.42" ] \
    || fail "pinned.example.com IP=$pin_ip, want 10.99.0.42:\n$hosts"

# Functional check: getent resolves the names. (getent ships with libc;
# `host` / `dig` are not in the minimal image.)
container exec -u coder --workdir "$ws" "$cont" getent hosts host.containers.internal >/dev/null \
    || fail "getent could not resolve host.containers.internal"
container exec -u coder --workdir "$ws" "$cont" getent hosts mac.local >/dev/null \
    || fail "getent could not resolve mac.local"
out=$(container exec -u coder --workdir "$ws" "$cont" getent hosts pinned.example.com)
echo "$out" | grep -q '10\.99\.0\.42' \
    || fail "getent pinned.example.com did not return 10.99.0.42: $out"

echo "OK test-host-aliases"
