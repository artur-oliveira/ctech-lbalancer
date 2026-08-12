#!/bin/bash
set -euo pipefail

STATIC_RANGES='2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32'

downloaded=$(curl --fail --silent --show-error --max-time 15 https://www.cloudflare.com/ips-v6 || true)
if [ "$(printf '%s\n' "$downloaded" | grep -Ec '^[0-9a-fA-F:]+/[0-9]{1,3}$')" -ge 7 ]; then
  ranges=$downloaded
else
  ranges=$STATIC_RANGES
fi

elements=$(printf '%s\n' "$ranges" \
  | grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' \
  | sort -u \
  | paste -sd, -)
if [ -z "$elements" ]; then
  echo 'No valid Cloudflare IPv6 ranges; keeping the existing firewall' >&2
  exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
mkdir -p /etc/nftables
cat > "$tmp" <<NFT
table inet ctech_edge {
  set cloudflare_v6 {
    type ipv6_addr
    flags interval
    elements = { ${elements} }
  }
  chain input {
    type filter hook input priority -10; policy accept;
    tcp dport 443 ip6 saddr @cloudflare_v6 accept
    tcp dport 443 drop
  }
}
NFT

nft --check --file "$tmp"
install -m 0600 "$tmp" /etc/nftables/ctech-edge.nft
cat > /etc/sysconfig/nftables.conf <<'CONF'
include "/etc/nftables/ctech-edge.nft"
CONF
nft delete table inet ctech_edge 2>/dev/null || true
nft --file /etc/nftables/ctech-edge.nft
