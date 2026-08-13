#!/bin/bash
set -euo pipefail

export AWS_DEFAULT_REGION=__AWS_REGION__
export AWS_USE_DUALSTACK_ENDPOINT=true

STATIC_CLOUDFLARE_V4='173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22'

STATIC_CLOUDFLARE_V6='2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32'

# First-boot fallback for AWS's managed CloudFront origin-facing prefix list.
# The daily refresh below is authoritative for IPv4. AWS does not publish an
# IPv6 managed prefix list, so retain its current three official IPv6 prefixes.
STATIC_CLOUDFRONT_ORIGIN='13.124.199.0/24
130.176.0.0/18
130.176.128.0/21
130.176.136.0/23
130.176.140.0/22
130.176.144.0/20
130.176.160.0/19
130.176.192.0/19
130.176.64.0/21
130.176.72.0/22
130.176.76.0/24
130.176.78.0/23
130.176.80.0/22
130.176.86.0/23
130.176.88.0/21
130.176.96.0/19
15.158.0.0/16
18.68.0.0/16
204.246.166.0/24
205.251.218.0/24
2600:9000:1000::/36
2600:9000:5200::/40
2600:9000:6000::/36
3.172.0.0/18
3.172.64.0/18
3.29.57.0/26
52.46.0.0/18
52.82.128.0/23
52.82.134.0/23
54.182.128.0/20
54.182.144.0/21
54.182.154.0/23
54.182.156.0/22
54.182.160.0/21
54.182.172.0/22
54.182.176.0/21
54.182.184.0/22
54.182.188.0/23
54.182.224.0/21
54.182.240.0/21
54.182.248.0/22
54.239.134.0/23
54.239.170.0/23
54.239.204.0/22
54.239.208.0/21
64.252.128.0/18
64.252.64.0/18
70.132.0.0/18'

STATIC_CLOUDFRONT_ORIGIN_V6='2600:9000:1000::/36
2600:9000:5200::/40
2600:9000:6000::/36'

CLOUDFLARE_PROXY_LIST=/etc/haproxy/cloudflare-proxies.lst
CLOUDFRONT_PROXY_LIST=/etc/haproxy/cloudfront-origin-proxies.lst
proxy_lists_changed=false

valid_ranges() {
  printf '%s\n' "$1" | grep -E '^[0-9a-fA-F:.]+/[0-9]{1,3}$' | sort -u || true
}

install_ranges() {
  destination=$1
  ranges=$2
  list_tmp=$(mktemp)
  valid_ranges "$ranges" > "$list_tmp"
  if [ ! -s "$list_tmp" ]; then
    echo "Refusing to empty ${destination}" >&2
    rm -f "$list_tmp"
    return 1
  fi
  if ! cmp -s "$list_tmp" "$destination"; then
    install -m 0644 "$list_tmp" "$destination"
    proxy_lists_changed=true
  fi
  rm -f "$list_tmp"
}

downloaded_v4=$(curl --fail --silent --show-error --max-time 15 https://www.cloudflare.com/ips-v4 || true)
downloaded_v6=$(curl --fail --silent --show-error --max-time 15 https://www.cloudflare.com/ips-v6 || true)
if [ "$(valid_ranges "$downloaded_v4" | wc -l)" -ge 15 ] && \
   [ "$(valid_ranges "$downloaded_v6" | wc -l)" -ge 7 ]; then
  cloudflare_ranges=$(printf '%s\n%s\n' "$downloaded_v4" "$downloaded_v6")
elif [ -s "$CLOUDFLARE_PROXY_LIST" ]; then
  cloudflare_ranges=$(cat "$CLOUDFLARE_PROXY_LIST")
else
  cloudflare_ranges=$(printf '%s\n%s\n' "$STATIC_CLOUDFLARE_V4" "$STATIC_CLOUDFLARE_V6")
fi

# ip-ranges.amazonaws.com has no IPv6 endpoint. Query the AWS-managed prefix
# list through the EC2 dual-stack API so this IPv6-only instance needs no NAT.
prefix_list_id=$(aws ec2 describe-managed-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text 2>/dev/null || true)
downloaded_cloudfront=''
if [ -n "$prefix_list_id" ] && [ "$prefix_list_id" != 'None' ]; then
  downloaded_cloudfront=$(aws ec2 get-managed-prefix-list-entries \
    --prefix-list-id "$prefix_list_id" --query 'Entries[].Cidr' --output text 2>/dev/null \
    | tr '\t' '\n' || true)
fi
if [ "$(valid_ranges "$downloaded_cloudfront" | wc -l)" -ge 40 ]; then
  cloudfront_ranges=$(printf '%s\n%s\n' "$downloaded_cloudfront" "$STATIC_CLOUDFRONT_ORIGIN_V6")
elif [ -s "$CLOUDFRONT_PROXY_LIST" ]; then
  cloudfront_ranges=$(cat "$CLOUDFRONT_PROXY_LIST")
else
  cloudfront_ranges=$STATIC_CLOUDFRONT_ORIGIN
fi

mkdir -p /etc/haproxy
install_ranges "$CLOUDFLARE_PROXY_LIST" "$cloudflare_ranges"
install_ranges "$CLOUDFRONT_PROXY_LIST" "$cloudfront_ranges"

# HAProxy only accepts IPv6 connections, so nftables needs only Cloudflare's
# IPv6 ranges even though request-chain resolution needs both address families.
if [ "$(valid_ranges "$downloaded_v6" | wc -l)" -ge 7 ]; then
  firewall_ranges=$downloaded_v6
else
  firewall_ranges=$STATIC_CLOUDFLARE_V6
fi
elements=$(valid_ranges "$firewall_ranges" | paste -sd, -)
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

if [ "$proxy_lists_changed" = true ] && systemctl is-active --quiet haproxy; then
  /usr/local/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg
  systemctl reload haproxy
fi
