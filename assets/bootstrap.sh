#!/bin/bash
set -euo pipefail

export AWS_DEFAULT_REGION=__AWS_REGION__
export AWS_USE_DUALSTACK_ENDPOINT=true

# A small swap file is deliberate: t4g.nano has 512 MiB and the compiler is only
# used at first boot, but swap also prevents an avoidable OOM during log bursts.
if [ ! -f /var/swapfile ]; then
  dd if=/dev/zero of=/var/swapfile bs=1M count=512 status=none
  chmod 600 /var/swapfile
  mkswap /var/swapfile
  swapon /var/swapfile
  echo '/var/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

# AL2023 Minimal already provides the curl command through curl-minimal. Asking
# DNF for the full curl package conflicts with curl-minimal and aborts cloud-init.
RUNTIME_PACKAGES=(jq nftables rsyslog amazon-ssm-agent libxcrypt openssl-libs pcre2 zlib)
if [ '__ENABLE_CLOUDWATCH__' = 'true' ]; then
  RUNTIME_PACKAGES+=(amazon-cloudwatch-agent)
fi
dnf install -y "${RUNTIME_PACKAGES[@]}" tar gzip

# Bring up the recovery path before the comparatively slow HAProxy source build.
# A later bootstrap failure must not leave an otherwise-running instance outside
# Session Manager.
cat > /etc/amazon/ssm/amazon-ssm-agent.json <<'SSM'
{ "Agent": { "Region": "__AWS_REGION__", "UseDualStackEndpoint": true } }
SSM
systemctl enable amazon-ssm-agent
systemctl restart amazon-ssm-agent

if ! id haproxy >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/haproxy --shell /sbin/nologin haproxy
fi
install -d -o haproxy -g haproxy -m 0750 /var/lib/haproxy
install -d -o haproxy -g haproxy -m 0750 /var/log/haproxy
install -d -o root -g haproxy -m 0750 /etc/haproxy/tls

HAPROXY_VERSION='__HAPROXY_VERSION__'
HAPROXY_BRANCH="${HAPROXY_VERSION%.*}"
HAPROXY_TARBALL="haproxy-${HAPROXY_VERSION}.tar.gz"
HAPROXY_ARTIFACT_BUCKET='__HAPROXY_ARTIFACT_BUCKET__'
HAPROXY_ARTIFACT_SHA256_PATH='__HAPROXY_ARTIFACT_SHA256_PATH__'
HAPROXY_ARTIFACT=/tmp/haproxy-artifact.tar.gz
artifact_installed=false

# The version-specific SSM value is the complete S3 object key: a lowercase
# SHA-256 digest of the bundle. An absent, invalid, unavailable, or corrupt cache
# entry safely falls back to the pinned source build below.
artifact_sha256=$(aws ssm get-parameter --name "$HAPROXY_ARTIFACT_SHA256_PATH" \
  --query Parameter.Value --output text 2>/dev/null || true)
if [[ "$artifact_sha256" =~ ^[0-9a-f]{64}$ ]] && \
   aws s3api get-object --bucket "$HAPROXY_ARTIFACT_BUCKET" \
     --key "$artifact_sha256" "$HAPROXY_ARTIFACT" >/dev/null 2>&1 && \
   echo "$artifact_sha256  $HAPROXY_ARTIFACT" | sha256sum --check --strict; then
  artifact_members=$(tar -tzf "$HAPROXY_ARTIFACT")
  if [ "$artifact_members" = 'usr/local/sbin/haproxy' ]; then
    tar -xzf "$HAPROXY_ARTIFACT" -C /
    chmod 0755 /usr/local/sbin/haproxy
    artifact_installed=true
    echo "Installed HAProxy ${HAPROXY_VERSION} artifact ${artifact_sha256}"
  else
    echo "Ignoring HAProxy artifact with unexpected members: ${artifact_members}" >&2
  fi
fi

if [ "$artifact_installed" != true ]; then
  dnf install -y gcc make binutils openssl-devel pcre2-devel zlib-devel
  curl --fail --silent --show-error --location \
    "https://www.haproxy.org/download/${HAPROXY_BRANCH}/src/${HAPROXY_TARBALL}" \
    --output "/tmp/${HAPROXY_TARBALL}"
  echo "__HAPROXY_SOURCE_SHA256__  /tmp/${HAPROXY_TARBALL}" | sha256sum --check --strict
  tar -xzf "/tmp/${HAPROXY_TARBALL}" -C /tmp
  make -C "/tmp/haproxy-${HAPROXY_VERSION}" -j1 \
    TARGET=linux-glibc USE_OPENSSL=1 USE_PCRE2=1 USE_ZLIB=1 USE_PROMEX=1
  make -C "/tmp/haproxy-${HAPROXY_VERSION}" install-bin PREFIX=/usr/local
  strip /usr/local/sbin/haproxy

  artifact_root=$(mktemp -d)
  install -D -m 0755 /usr/local/sbin/haproxy \
    "$artifact_root/usr/local/sbin/haproxy"
  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$artifact_root" -cf - usr/local/sbin/haproxy | gzip -n -9 > "$HAPROXY_ARTIFACT"
  artifact_sha256=$(sha256sum "$HAPROXY_ARTIFACT" | awk '{print $1}')

  # Cache publication is best-effort: the verified local binary remains usable
  # if S3 or SSM has a transient write failure.
  if aws s3api put-object --bucket "$HAPROXY_ARTIFACT_BUCKET" \
      --key "$artifact_sha256" --body "$HAPROXY_ARTIFACT" \
      --checksum-algorithm SHA256 >/dev/null; then
    aws ssm put-parameter --name "$HAPROXY_ARTIFACT_SHA256_PATH" \
      --type String --value "$artifact_sha256" --overwrite >/dev/null || \
      echo "HAProxy artifact uploaded but its SSM pointer could not be updated" >&2
  else
    echo "HAProxy artifact cache upload failed; continuing with the local binary" >&2
  fi

  rm -rf "/tmp/${HAPROXY_TARBALL}" "/tmp/haproxy-${HAPROXY_VERSION}" "$artifact_root"
  dnf remove -y gcc make binutils openssl-devel pcre2-devel zlib-devel
  dnf clean all
fi

# Do not pipe this through `head` under pipefail: HAProxy then receives SIGPIPE,
# returns 141, and aborts the remainder of cloud-init despite a successful build.
/usr/local/sbin/haproxy -vv

cat > /etc/systemd/system/haproxy.service <<'UNIT'
[Unit]
Description=HAProxy LTS edge proxy
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/haproxy/haproxy.cfg

[Service]
Environment=HAPROXY_MWORKER=1
ExecStart=/usr/local/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid
ExecReload=/usr/local/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg
ExecReload=/bin/kill -USR2 $MAINPID
KillMode=mixed
Restart=always
RestartSec=2s
LimitNOFILE=65536
RuntimeDirectory=haproxy
RuntimeDirectoryMode=0750

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/rsyslog.d/49-haproxy.conf <<'RSYSLOG'
module(load="imudp")
input(type="imudp" address="127.0.0.1" port="514")
template(name="HAProxyMessage" type="string" string="%msg%\n")
if ($programname == 'haproxy') then {
  action(type="omfile" file="/var/log/haproxy/access.log" template="HAProxyMessage")
  stop
}
RSYSLOG

cat > /etc/logrotate.d/ctech-lbalancer <<'LOGROTATE'
/var/log/haproxy/access.log {
  daily
  rotate 3
  size 20M
  missingok
  notifempty
  compress
  copytruncate
}
LOGROTATE

if [ '__ENABLE_CLOUDWATCH__' = 'true' ]; then
  mkdir -p /etc/systemd/system/amazon-cloudwatch-agent.service.d
  cat > /etc/systemd/system/amazon-cloudwatch-agent.service.d/override.conf <<'CWAENV'
[Service]
Environment=AWS_USE_DUALSTACK_ENDPOINT=true
CWAENV
  cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWA'
{
  "agent": {"run_as_user":"root"},
  "logs": {"logs_collected":{"files":{"collect_list":[
    {"file_path":"/var/log/haproxy/access.log","log_group_name":"__ACCESS_LOG_GROUP__","log_stream_name":"{instance_id}/access"}
  ]}}}
}
CWA
  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
fi

cat > /etc/systemd/system/ctech-cloudflare-ips.service <<'UNIT'
[Unit]
Description=Refresh trusted CDN ranges and Cloudflare-only IPv6 firewall
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/ctech-lbalancer/refresh-cloudflare-ips.sh
UNIT

cat > /etc/systemd/system/ctech-cloudflare-ips.timer <<'UNIT'
[Unit]
Description=Daily trusted CDN range and Cloudflare IPv6 allowlist refresh

[Timer]
OnBootSec=2min
OnUnitActiveSec=1d
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/ctech-lbalancer-reconcile.service <<'UNIT'
[Unit]
Description=Reconcile HAProxy routes and ASG targets
After=network-online.target ctech-cloudflare-ips.service rsyslog.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=AWS_USE_DUALSTACK_ENDPOINT=true
ExecStart=/opt/ctech-lbalancer/reconcile.sh
UNIT

cat > /etc/systemd/system/ctech-lbalancer-reconcile.timer <<'UNIT'
[Unit]
Description=Reconcile HAProxy routes every 30 seconds

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
/opt/ctech-lbalancer/refresh-cloudflare-ips.sh
systemctl enable nftables rsyslog
systemctl restart rsyslog
systemctl enable --now ctech-cloudflare-ips.timer ctech-lbalancer-reconcile.timer
/opt/ctech-lbalancer/reconcile.sh || true
