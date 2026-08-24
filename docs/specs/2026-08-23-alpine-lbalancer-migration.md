# Alpine AMI Migration for ctech-lbalancer

**Goal:** Give `ctech-lbalancer` an Alpine ARM64 boot path (ctech-cdk's
`/ctech/{env}/ami/alpine/arm64`) as an alternative to its current AL2023
minimal path, selectable per-environment via a Terraform variable, with no
change to routing/TLS/CORS/auto-heal behavior.

**Non-goal:** Deleting or replacing the AL2023 path. It stays the default
and fully supported, mirroring ctech-cdk's own policy for the Alpine AMI
pipeline.

## Background

ctech-cdk (sibling repo) just finished a live-debugged Alpine ARM64 AMI pilot
for `ValkeyStackV2`, a much simpler service than this one. Eight real bugs
were found and fixed one at a time on a running instance, all now committed
in ctech-cdk:

1. Alpine's cloud-init never executes EC2 user-data at all — worked around
   with a custom OpenRC service (`/etc/init.d/ctech-userdata`) that fetches
   and runs it directly via IMDS.
2. `bash`, `curl`, `util-linux` (for `mkswap`) are not on the base image —
   added to the Packer build.
3. busybox `adduser -S` does not create a same-named group — needs an
   explicit `addgroup -S` first.
4. `ssm-user` (Session Manager's session account) has no `doas` permission
   by default — needs `permit nopass ssm-user` in `/etc/doas.conf`.
5. apk packages don't always create the directories their own OpenRC
   `start_pre()` assumes exist (confirmed for `valkey`; assume nothing here
   without checking each package used).
6. A hand-built IAM resource ARN string can silently drift from the actual
   resource name — reference the CDK/Terraform construct's own ARN attribute
   instead of duplicating the string.

This spec applies the same "Alpine is optional, AL2023 stays fully
supported" policy and the same construct (`ctech-ec2-agent`, the Go binary
that replaces `aws-cli` on musl) that ctech-cdk already built.

## Scope decision (approved by user, this session)

- **Rollout topology:** replace the AMI directly on the existing
  `aws_launch_template.this` / `aws_autoscaling_group.this` (both already
  `create_before_destroy = true`), gated by a new `var.os_family` variable.
  No parallel canary ASG. Rollback is `os_family = "al2023"` +
  `terraform apply` — no file changes needed either direction.
- Everything AL2023-specific stays. Every Alpine-specific piece is new,
  parallel code, never a rewrite of the existing files.

## What was verified live before writing this spec

All of the following were tested directly on a running Alpine ARM64
instance (the ctech-cdk Valkey pilot box) during this session, not assumed:

- **nftables**: `apk add nftables` + `nft list ruleset` — kernel supports
  `nf_tables`, no blocker.
- **rsyslog + `imudp`**: `apk add rsyslog`, wrote the exact
  `/etc/rsyslog.d/49-haproxy.conf` this repo already uses, started the
  service, sent a test message via `logger -p local2.info -t haproxy`, and
  it landed in `/var/log/haproxy/access.log` exactly as designed. Only gap:
  the apk package does not create `/etc/rsyslog.d/`; the bootstrap script
  must `mkdir -p` it first.
- **nftables-openrc persistence**: `/etc/init.d/nftables` loads
  `$rules_file` (default `/etc/nftables.nft`) via `nft -f` on `start`, and
  its own `/etc/conf.d/nftables` comment recommends the same
  `include "/etc/nftables.d/<name>.nft"` pattern this repo already uses for
  `/etc/sysconfig/nftables.conf` on AL2023 — just a different top-level
  file path and `rc-update add nftables default` for boot persistence,
  instead of `systemctl enable nftables`.
- **HAProxy compiled from source with `TARGET=linux-musl`**: built
  HAProxy 3.4.3 with `USE_OPENSSL=1 USE_PCRE2=1 USE_ZLIB=1 USE_PROMEX=1`
  (the exact flags this repo's config needs, including the Prometheus
  exporter `reconcile.sh.tftpl` depends on) — compiled clean, `haproxy -vv`
  confirms all four options built in.
- **1 GiB root volume budget for the HAProxy build**: this was the tight
  one. Toolchain (`build-base openssl-dev pcre2-dev zlib-dev linux-headers`)
  plus HAProxy's source tree and object files peaked at ~841 MiB used out of
  953 MiB available — a live build attempt genuinely ran out of disk once
  during testing with a 256 MiB swap file in place; shrinking swap to
  **128 MiB** (not 256 MiB) freed enough space for the same build to
  complete. The toolchain and source tree are removed after the build (the
  existing `dnf remove`/`rm -rf` pattern in `bootstrap.sh.tftpl` already
  does this), so this is a peak-usage constraint during boot, not a
  steady-state one — but it has near-zero margin. **128 MiB swap is now a
  hard requirement for the Alpine path, not a tunable.**

## Design

### 1. HAProxy build: source-compiled, `TARGET=linux-musl` (not the apk package)

Decision: keep compiling from source (same S3-artifact-cache-by-sha256
pattern `bootstrap.sh.tftpl` already has), only changing `TARGET=linux-glibc`
to `TARGET=linux-musl` and swapping the AL2023 dnf dev packages for their
Alpine apk equivalents:

| AL2023 (dnf) | Alpine (apk) |
|---|---|
| `gcc make binutils openssl-devel pcre2-devel zlib-devel` | `build-base openssl-dev pcre2-dev zlib-dev linux-headers` |

`linux-headers` is not part of `build-base` on Alpine and must be listed
explicitly — the build fails on `linux/types.h: No such file or directory`
without it (confirmed live).

Rejected alternative: install HAProxy via Alpine's own `haproxy` apk
package. Simpler (no build toolchain, no S3 artifact cache needed at all),
but whether that package is built with `USE_PROMEX=1` was unverified and
`reconcile.sh.tftpl`'s `/metrics` frontend depends on it. Source-compiling
keeps that guarantee explicit. This can be revisited later as its own
follow-up if the apk package's build flags are ever confirmed to include
Prometheus support.

### 2. `ctech-ec2-agent`: five new subcommands

`ctech-ec2-agent` (ctech-cdk's `aws-cli` replacement for musl, Go,
`assets/ctech-ec2-agent/`) already has `ssm-get`, `ssm-put`, `prefix-list`,
`route53-upsert`, `s3-cp`, `s3-head`, `logs-tail`. This service's scripts
need five more, all new Go code in that same ctech-cdk module (this spec's
implementation plan should include this cross-repo change explicitly — it's
ctech-cdk's binary, so it must be built and released there first):

| Subcommand | Replaces | Used by |
|---|---|---|
| `ssm-get-by-path` | `aws ssm get-parameters-by-path --recursive` | `reconcile.sh` reading all routes at once |
| `asg-describe` | `aws autoscaling describe-auto-scaling-groups` | `reconcile.sh` resolving backend targets |
| `ec2-describe-instances` | `aws ec2 describe-instances` | `reconcile.sh` resolving target private IPs |
| `asg-set-unhealthy` | `aws autoscaling set-instance-health` | `reconcile.sh` auto-heal |
| `s3-put` | `aws s3api put-object --checksum-algorithm SHA256` | `bootstrap.sh` HAProxy artifact cache upload |

`s3-cp` today only downloads; `s3-put` is a new, separate subcommand rather
than an added flag, matching the existing one-subcommand-per-operation
shape of the rest of the binary.

### 3. systemd → OpenRC

| Systemd unit | Alpine replacement |
|---|---|
| `haproxy.service` | Standard OpenRC service script (`command`, `pidfile`, `supervisor="supervise-daemon"`), same shape as ctech-cdk's `setup-app-service.sh`. `ExecReload`'s `kill -USR2` maps to `rc-service haproxy reload`. |
| `ctech-cloudflare-ips.service` + `.timer` (daily) | `/etc/periodic/daily`, same jittered-sleep pattern ctech-cdk's `setup-realip.sh` already uses (`OpenRC`/busybox `crond` has no `RandomizedDelaySec` equivalent). |
| `ctech-lbalancer-reconcile.service` + `.timer` (every 30s, `AccuracySec=5s`) | **Not cron** — busybox `crond`'s finest granularity is one minute. Becomes a persistent OpenRC service running `while true; do /opt/ctech-lbalancer/reconcile.sh; sleep 30; done` under `supervise-daemon` (auto-restarts if it ever dies). This is the one behavioral-shape change in this migration: a periodic oneshot timer becomes a supervised long-running loop. |
| `rsyslog.service` | `rsyslog` apk package + OpenRC service (verified above). Bootstrap must `mkdir -p /etc/rsyslog.d` first — the package doesn't create it. |
| `logrotate` (systemd timer, implicit via cron on AL2023) | `logrotate` apk package, same `/etc/logrotate.d/ctech-lbalancer` config, run via `/etc/periodic/daily` (logrotate itself is not a service). |

### 4. nftables

Functionally unchanged — the script already applies the ruleset immediately
via `nft --file /etc/nftables/ctech-edge.nft`, which needs nothing OS-specific.
Only the *persistence* path changes: instead of writing
`/etc/sysconfig/nftables.conf` (RHEL/systemd-specific, read by AL2023's
`nftables.service`) with an `include`, write `/etc/nftables.nft` with the
same `include "/etc/nftables/ctech-edge.nft"` line, and
`rc-update add nftables default` instead of `systemctl enable nftables`.

### 5. Disk budget: 1 GiB root volume (down from AL2023's 4 GiB), 128 MiB swap

Matches ctech-cdk's own Alpine target. Verified tight but sufficient for the
HAProxy build (see "What was verified live" above). `var.os_family` gates
`block_device_mappings.volume_size`: `4` for `"al2023"` (unchanged), `1` for
`"alpine"`.

### 6. File structure

New files only, existing ones untouched:

- `assets/bootstrap-alpine.sh.tftpl`
- `assets/reconcile-alpine.sh.tftpl`
- `assets/refresh-cloudflare-ips-alpine.sh.tftpl`
- `terraform/lbalancer/data.tf`: add
  `data.aws_ssm_parameter.alpine_arm64_ami` (`/ctech/{env}/ami/alpine/arm64`)
  and `data.aws_ssm_parameter.ec2_scripts_alpine_{bucket,version}`
  (`/ctech/{env}/ec2-scripts-alpine/{bucket,version}`, ctech-cdk's existing
  Alpine script-publishing pointers — parallel to the `ec2_scripts_bucket`/
  `ec2_scripts_version` pair already read for AL2023).
- `terraform/lbalancer/variables.tf`: new `var.os_family` (`"al2023"` default
  or `"alpine"`), validated against those two values.
- `terraform/lbalancer/compute.tf`: `image_id`, the three `templatefile()`
  sources, and `block_device_mappings.volume_size` all branch on
  `var.os_family`.
- `terraform/lbalancer/iam.tf`: add the five new `ctech-ec2-agent` actions
  (`ssm:GetParametersByPath` is already granted; `autoscaling:*`,
  `ec2:DescribeInstances` are already granted for `ReconcileDiscovery`/
  `AutoHeal` — the existing policy document already covers every IAM action
  the five new subcommands need. No IAM changes required beyond what's
  already there.)

## Risks and open questions for the implementation plan

- The 128 MiB swap / 1 GiB disk margin is tight (verified ~30-110 MiB spare
  at peak, depending on measurement point). A future HAProxy version bump
  could tip this over; the plan should include a live build test on every
  HAProxy version change, not just once now.
- `logrotate` and the `while … sleep 30` reconcile loop are new-to-Alpine
  patterns not yet tested live in this session — the plan should verify
  both directly on a live instance before considering the migration done,
  the same way nftables/rsyslog/HAProxy were verified here.
- `ctech-ec2-agent`'s five new subcommands are cross-repo work (ctech-cdk),
  gating this repo's own implementation — the plan should call this out as
  its own task/dependency, not something silently done inline.
