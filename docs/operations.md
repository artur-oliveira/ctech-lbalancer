# Operations runbook

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
does not require a CDK deployment. A private-CA rotation is a separate,
zone-wide procedure and must prepare every deployed environment before the
Cloudflare certificate changes.

## 2. Configure Cloudflare DNS automation

Create a token limited to **Zone / DNS / Edit** for only `aoctech.app`, then:

```bash
aws ssm put-parameter --type SecureString \
  --name /ctech/global/cloudflare/dns-api-token \
  --value "$(<cloudflare-dns-token.txt)" --overwrite
```

Pass the non-secret zone ID as `CLOUDFLARE_ZONE_ID` during CDK synth/deploy.
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
- `CF-Connecting-IP` becomes the application client IP;
- unknown Host returns 421;
- stopped target becomes HAProxy `DOWN` after about 15 seconds;
- replacement ASG target appears within about 30 seconds of reaching `InService`;
- forced load-balancer instance termination causes its ASG to replace it and the
  origin AAAA to update.

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

HAProxy does not forward to a target until two consecutive health checks pass.
It stops forwarding after three failures. With `autoHeal=true`, the reconciler
waits for three of its own failures before asking the ASG to replace the target.
Set `autoHeal=false` before intentional maintenance longer than roughly 90
seconds, or put the ASG instance in standby.

## 5. Upgrade HAProxy

Patch upgrades are intentionally code changes. Update `HAPROXY_VERSION` and
`HAPROXY_SOURCE_SHA256` in `lib/constants.ts`, run build/tests/synth, deploy to dev, then
stage and prod. Never point the bootstrap at an unpinned `latest` artifact.

Each version has a global cache pointer at
`/ctech/global/lbalancer/haproxy/{version}/al2023-arm64/artifact-sha256`. Its
value is also the complete object key in the retained
`ctech-lbalancer-artifacts` bucket. On a cache miss, the first
instance verifies the official source archive, compiles and strips HAProxy,
creates a deterministic single-file bundle, uploads it with an S3 SHA-256
checksum, and records the bundle hash. All later environments and replacements
download and independently verify that hash before extraction.

Inspect the active artifact without changing it:

```bash
VERSION=3.4.3
HASH="$(aws ssm get-parameter \
  --name "/ctech/global/lbalancer/haproxy/${VERSION}/al2023-arm64/artifact-sha256" \
  --query Parameter.Value --output text)"
BUCKET="$(aws cloudformation describe-stacks \
  --stack-name Ctech-LoadBalancerArtifacts \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text)"
aws s3api head-object --bucket "$BUCKET" --key "$HASH" --checksum-mode ENABLED
```

If a first boot compiled HAProxy but could not publish the cache, connect to that
instance with Session Manager and publish the already-created bundle. Run this
as root; the SSM pointer is written only after the S3 upload succeeds:

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

Do not use an S3 ETag as the artifact identity. To force a carefully reviewed
rebuild of the same pinned version, delete only its SSM pointer; never delete a
hash-addressed object still referenced by that parameter. A missing object or
checksum mismatch falls back to the pinned source build.

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
- **CPU credits:** nano has a 5% baseline. Watch both `CPUCreditBalance` and
  `CPUSurplusCreditsCharged`; move back to micro if the latter becomes nonzero or
  latency rises. Standard mode is not used because T4g has no launch credits and
  would make first-boot compilation/recovery unacceptably slow.
- **Memory:** 512 MiB is enough for this small route set and includes 512 MiB
  swap, but avoid adding a large control plane or per-request scripting.
- **Logs:** local logs rotate at 20 MiB/three days. With CloudWatch disabled they
  disappear on replacement; metrics remain live-only.
- **Cross-AZ traffic:** a target in another AZ incurs regional data transfer.
- **Bad health endpoint:** auto-heal will correctly but repeatedly replace an app
  whose health contract is wrong. Test the route with `autoHeal=false` first.
