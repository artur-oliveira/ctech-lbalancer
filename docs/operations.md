# Operations runbook

For the separate private Route 53 and M2M HTTPS entrypoint, follow the complete
[private M2M runbook](internal-m2m.md). The public Cloudflare/AOP procedures in
this document remain unchanged.

## 1. Create the Cloudflare certificates

Two different certificates solve two different problems:

1. **Origin CA server certificate** — HAProxy presents this to Cloudflare.
   In Cloudflare, create an ECC PEM Origin Certificate for `aoctech.app` and
   `*.aoctech.app`. The wildcard covers all current prod/dev/stage naming because
   they are one label below the zone. It does not cover a name such as
   `api.dev.aoctech.app`; add `*.dev.aoctech.app` if naming ever changes that way.
2. **Zone-level Authenticated Origin Pull certificate** — Cloudflare presents
   this client certificate to HAProxy. Create a private CA, sign a leaf client
   certificate, upload the leaf certificate and key to Cloudflare, and store
   only the CA certificate on the origin. Do not store the CA private key in AWS.

Set the zone encryption mode to **Full (strict)**, enable zone-level
Authenticated Origin Pulls, enable **Always Use HTTPS**, and only then enforce
client verification at the new origin.

Store the server material in free SSM Standard SecureString parameters. Use PEM
exactly as copied; shell history is not a safe place for private keys, so load
them from files:

```bash
ENVIRONMENT=prod
aws ssm put-parameter --type SecureString \
  --name "/ctech/${ENVIRONMENT}/lbalancer/tls/origin-certificate" \
  --value "$(<origin-cert.pem)" --overwrite --profile ctech --region us-east-1
aws ssm put-parameter --type SecureString \
  --name "/ctech/${ENVIRONMENT}/lbalancer/tls/origin-private-key" \
  --value "$(<origin-key.pem)" --overwrite --profile ctech --region us-east-1
aws ssm put-parameter --type SecureString \
  --name "/ctech/${ENVIRONMENT}/lbalancer/tls/aop-ca" \
  --value "$(<aop-root-ca.pem)" --overwrite --profile ctech --region us-east-1
```

The default 4 KiB Standard Parameter limit applies. ECC server material fits.
If an RSA chain exceeds it, prefer ECC instead of paying for Advanced Parameters.

Record the certificate IDs and expiration dates, then follow
[the AOP certificate renewal runbook](aop-certificate-renewal.md) when
Cloudflare sends its 30-day expiration notification. Routine AOP leaf renewal
does not require a Terraform deployment. A private-CA rotation is a separate,
zone-wide procedure and must prepare every deployed environment before the
Cloudflare certificate changes.

## 2. Configure Cloudflare DNS automation

Create a token limited to **Zone / DNS / Edit** for only `aoctech.app`, then:

```bash
aws ssm put-parameter --type SecureString \
  --name /ctech/global/cloudflare/dns-api-token \
  --value "$(<cloudflare-dns-token.txt)" --overwrite
```

Pass the non-secret zone ID as `cloudflare_zone_id` (Terraform variable, in
`environments/{env}.tfvars` or `-var`) when running `terraform apply`.
The reconciler creates or updates:

```text
origin.aoctech.app  AAAA  <current LB IPv6>  DNS only
```

Create these Cloudflare records manually for the initial migration:

```text
accounts-api.aoctech.app  CNAME  origin.aoctech.app  Proxied
dfe-api.aoctech.app       CNAME  origin.aoctech.app  Proxied
wallet-api.aoctech.app    CNAME  origin.aoctech.app  Proxied
poker-api.aoctech.app     CNAME  origin.aoctech.app  Proxied
```

Dev and stage use `origin-dev.aoctech.app` and `origin-stage.aoctech.app`, plus
the existing `*-dev` / `*-stage` public names.

## 3. Validate before cutover

Get the origin IPv6 written by the instance:

```bash
aws ssm get-parameter --name /ctech/prod/lbalancer/origin-ipv6 \
  --query Parameter.Value --output text
```

A direct request without the AOP client certificate must fail at the firewall
or TLS handshake. Validate through a temporary proxied Cloudflare hostname, then
check all of the following:

- normal API request and health endpoint;
- WebSocket upgrade and a connection longer than 65 seconds (poker);
- direct API traffic reports `CF-Connecting-IP` as the application client IP;
- same-origin `/v1.0/*` traffic through CloudFront reports the original viewer,
  not an AWS CloudFront origin-facing address such as `15.158.0.0/16`;
- a client-supplied leftmost `X-Forwarded-For` value does not change the
  application IP;
- unknown Host returns 421;
- stopped target becomes HAProxy `DOWN` after about 15 seconds;
- an allowed cross-origin `OPTIONS` request returns 204 with CORS headers even
  while every target of that API is stopped;
- replacement ASG target appears within about 30 seconds of reaching `InService`;
- forced load-balancer instance termination causes its ASG to replace it and the
  origin AAAA to update as soon as the replacement HAProxy starts listening.

## 4. Inspect health and configuration

An EC2/ASG `Healthy` state only checks that the virtual machine is running; it
does not prove cloud-init completed or that SSM registered. If Session Manager
shows the agent offline, inspect the serial console without logging into the
instance:

```bash
INSTANCE_ID="$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names prod-ctech-lbalancer \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)"
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}"
aws ec2 get-console-output --instance-id "$INSTANCE_ID" --latest \
  --query Output --output text
```

The load balancer attaches two security groups deliberately: the imported
shared edge SG remains the identity trusted by backend service SGs, while a
dedicated egress-only SG supplies the `::/0` outbound rule required by this
public-IPv6/no-public-IPv4 instance. The bootstrap retains AL2023 Minimal's
`curl-minimal` package and starts the dual-stack SSM agent before downloading or
building HAProxy, leaving Session Manager available if a later step fails.

```bash
aws ssm start-session --target INSTANCE_ID
sudo systemctl status haproxy ctech-lbalancer-reconcile.timer
sudo journalctl -u ctech-lbalancer-reconcile.service -n 100 --no-pager
sudo /usr/local/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg
sudo nft list table inet ctech_edge
```

With CloudWatch log streaming enabled (the default), verify both Alpine
`ctech-ec2-agent` streams without opening a session:

```bash
aws logs tail /ctech-lbalancer/prod/access --since 10m --follow
```

Streams prefixed with `access/` contain HAProxy JSON access events; streams
prefixed with `reconcile/` contain discovery, DNS, certificate and auto-heal
failures. On AL2023 the stream names use `{instance_id}/access` and
`{instance_id}/reconcile` instead.

HAProxy does not forward to a target until two consecutive health checks pass.
It stops forwarding after three failures. With `autoHeal=true`, the reconciler
waits for three of its own failures before asking the ASG to replace the target.
Set `autoHeal=false` before intentional maintenance longer than roughly 90
seconds, or put the ASG instance in standby.

## 5. Upgrade HAProxy

Patch upgrades are intentionally code changes. Update `version` and
`source_sha256` in `build/haproxy.json` together. If the Alpine release used by
the AMI changes, update `alpine_version` there too. Never point the bootstrap at
an unpinned `latest` artifact.

The `HAProxy ARM64 Artifact` workflow runs on a native GitHub-hosted ARM64
runner. Its Docker build verifies the source archive, compiles and strips
HAProxy against Alpine/musl, confirms Prometheus exporter support, and exports
only `/usr/local/sbin/haproxy`. The workflow creates a deterministic bundle,
uploads it under its SHA-256 in `ctech-lbalancer-artifacts`, downloads it again
for verification, and only then updates
`/ctech/global/lbalancer/haproxy/{version}/alpine-arm64/artifact-sha256`.

The workflow assumes `ctech-lbalancer-gha-haproxy` through GitHub OIDC. Apply
`terraform/github` once from a trusted workstation before its first run. Its
trust is restricted to this repository's `main` branch and its policy can write
only this bucket and Alpine HAProxy pointer paths.

Merge the manifest change and wait for the artifact workflow to succeed before
applying a launch-template change or replacing an Alpine instance. Alpine boot
is intentionally download-only: a missing pointer, missing object, digest
mismatch, or unexpected archive member stops bootstrap instead of compiling on
the T4g.nano.

Inspect the active artifact without changing it:

```bash
VERSION=3.4.3
HASH="$(aws ssm get-parameter \
  --name "/ctech/global/lbalancer/haproxy/${VERSION}/alpine-arm64/artifact-sha256" \
  --query Parameter.Value --output text)"
BUCKET=ctech-lbalancer-artifacts
aws s3api head-object --bucket "$BUCKET" --key "$HASH" --checksum-mode ENABLED
```

To rebuild the same pinned version, manually dispatch `HAProxy ARM64 Artifact`
on `main`. Content-addressing makes an identical build reuse the same object;
the pointer is written only after the uploaded bytes have been downloaded and
verified. The EC2 role cannot publish or repair Alpine artifacts.

AL2023 still uses the legacy on-instance cache builder. If an AL2023 first boot
compiled HAProxy but could not publish its cache, connect with Session Manager
and publish the already-created bundle as root:

```bash
sudo -i
export AWS_DEFAULT_REGION=us-east-1
export AWS_USE_DUALSTACK_ENDPOINT=true

ARTIFACT=/tmp/haproxy-artifact.tar.gz
BUCKET=ctech-lbalancer-artifacts
POINTER=/ctech/global/lbalancer/haproxy/3.4.3/al2023-arm64/artifact-sha256

test "$(tar -tzf "$ARTIFACT")" = usr/local/sbin/haproxy
HASH="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
aws s3api put-object \
  --bucket "$BUCKET" --key "$HASH" --body "$ARTIFACT" \
  --checksum-algorithm SHA256
aws ssm put-parameter \
  --name "$POINTER" --type String --value "$HASH" --overwrite

VERIFY="$(mktemp)"
aws s3api get-object --bucket "$BUCKET" --key "$HASH" "$VERIFY"
echo "$HASH  $VERIFY" | sha256sum --check --strict
rm -f "$VERIFY"
aws ssm get-parameter --name "$POINTER" \
  --query Parameter.Value --output text
```

If `/tmp/haproxy-artifact.tar.gz` is absent, recreate the same deterministic
bundle from the installed binary before running the upload block:

```bash
ARTIFACT_ROOT="$(mktemp -d)"
install -D -m 0755 /usr/local/sbin/haproxy \
  "$ARTIFACT_ROOT/usr/local/sbin/haproxy"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  -C "$ARTIFACT_ROOT" -cf - usr/local/sbin/haproxy | \
  gzip -n -9 > /tmp/haproxy-artifact.tar.gz
rm -rf "$ARTIFACT_ROOT"
```

Do not use an S3 ETag as the artifact identity and never delete a hash-addressed
object while a pointer references it. For Alpine, do not delete the SSM pointer
to force a rebuild: rerun the workflow, verify it, and leave the last valid
pointer available throughout.

Changing launch-template user data starts an ASG instance refresh only when you
explicitly request one. After deployment, replace the one load-balancer member:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name prod-ctech-lbalancer \
  --preferences MinHealthyPercentage=0,InstanceWarmup=600
```

Expect a short outage with a one-instance ASG. Schedule this or temporarily set
desired/max capacity to two for a rolling upgrade, then return both to one.

## 6. ALB migration changes in sibling projects

Do not destroy the ALB stack first. Each service currently creates an ALB target
group/listener rule and configures ASG ELB health checks through
`@aoctech/cdk`'s `PrivateIpv4Ec2Service`.

Migration sequence:

1. Deploy this stack and validate parallel traffic.
2. Change each service construct to retain its ASG, instance SG, port, and local
   systemd restart policy, but remove the listener rule/target group dependency.
3. Have each service CDK own its route SSM parameter. Import or remove the three
   bootstrap parameters from this stack during that ownership transfer; two
   CloudFormation stacks cannot own the same parameter name.
4. Confirm app-level replacement through this reconciler (`autoHeal=true`).
5. Change CloudFront API origins and public API Cloudflare records to HAProxy.
6. Observe error counts and target replacement for at least a day.
7. Delete the ALB resources, but retain the shared edge security group. Rename
   `/network/alb-sg-id` later as a no-downtime cleanup; this stack deliberately
   reuses it so current service SG ingress works during migration.

## Failure modes to keep in mind

- **LB is a single point in time:** ASG recovery is automatic, not instant.
- **Cloudflare dependency:** an outage or accidental DNS de-proxy makes the
  public service unavailable by design; direct browsers cannot trust Origin CA.
- **Certificate expiry:** Origin CA can be long lived, but inventory its expiry;
  set Cloudflare AOP expiry alerts for the client certificate and use the
  [renewal runbook](aop-certificate-renewal.md) at the 30-day warning.
- **CPU credits:** nano has a 5% baseline. It runs in T4g Standard mode, so it
  throttles after exhausting `CPUCreditBalance` instead of charging for surplus
  credits. Moving compilation to CI makes replacement time independent of that
  balance; move back to micro if normal request latency rises under throttling.
- **Memory:** 512 MiB is enough for this small route set and includes 128 MiB
  swap, but avoid adding a large control plane or per-request scripting.
- **Logs:** local logs rotate at 20 MiB/three days. JSON entries include the
  HAProxy queue, backend-connect, backend-response, and total timings in
  milliseconds. `tls_protocol` and `tls_cipher` refer to Cloudflare's mutually
  authenticated TLS connection to HAProxy, while `cf_ray` correlates the edge
  request without logging client IPs or request URLs. With CloudWatch disabled they
  disappear on replacement; metrics remain live-only.
- **Cross-AZ traffic:** a target in another AZ incurs regional data transfer.
- **Bad health endpoint:** auto-heal will correctly but repeatedly replace an app
  whose health contract is wrong. Test the route with `autoHeal=false` first.
