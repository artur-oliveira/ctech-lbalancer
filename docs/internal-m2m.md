# Private M2M through HAProxy

This runbook enables service-to-service HTTPS without Cloudflare while keeping
the existing public path unchanged.

```text
external client -> Cloudflare -> HAProxy IPv6:443 (AOP mTLS) --+
                                                            +-> service ASG
internal client -> private Route 53 -> HAProxy IPv4:443 -----+
```

The private entrypoint is not a second load balancer. Both frontends share the
same HAProxy backends, active health checks, target discovery, and auto-healing.
The default private names are:

| Service | Private URL |
|---|---|
| Account | `https://accounts.internal.aoctech.app` |
| DFE | `https://dfe.internal.aoctech.app` |
| Wallet | `https://wallet.internal.aoctech.app` |
| Poker | `https://poker.internal.aoctech.app` |

Each name is a private CNAME to `lbalancer.internal.aoctech.app`. The HAProxy
instance reconciles that target's private `A` record with TTL 10 seconds. Do not
call `lbalancer.internal.aoctech.app` directly: routing is by service hostname,
so the generic name intentionally returns HTTP 421.

## Security boundaries

- The public IPv6 frontend still admits only Cloudflare ranges and still
  requires the Cloudflare Authenticated Origin Pull client certificate.
- The internal frontend binds only IPv4 on an instance with no public IPv4.
  `nftables` admits it only from the VPC CIDR.
- The frontends use separate server certificates. The private certificate must
  cover `*.internal.aoctech.app`.
- The internal frontend deletes `Forwarded`, `CF-Connecting-IP`,
  `True-Client-IP`, `X-Forwarded-For`, and `X-Real-IP`, then rebuilds the last
  two from the TCP source address.
- This implementation authenticates the server, not the calling workload.
  Continue requiring the service's normal M2M token/signature. VPC membership
  is not an authorization mechanism. Per-service client mTLS can be added later
  if transport-level workload identity becomes a requirement.

## 1. Preflight

Use the same AWS account/region/profile used for production:

```bash
export AWS_PROFILE=ctech
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1

PRIVATE_ZONE_ID="$(aws ssm get-parameter \
  --name /ctech/global/dns/private-hosted-zone-id \
  --query Parameter.Value --output text)"
aws route53 get-hosted-zone --id "$PRIVATE_ZONE_ID"
aws ssm get-parameter \
  --name /ctech/prod/network/vpc-id \
  --query Parameter.Value --output text
```

The hosted zone must be `internal.aoctech.app` and must be associated with the
production VPC. Stop here if either value differs.

## 2. Issue the private server certificate

Follow Cloudflare's [Origin CA procedure](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/).
Open **SSL/TLS > Origin Server > Create Certificate** for `aoctech.app` and
choose:

- Cloudflare generates the private key and CSR;
- RSA key for broad client compatibility;
- hostname `*.internal.aoctech.app`;
- PEM format;
- a validity period that matches the team's certificate policy.

Save the one-time private key and certificate locally as
`internal-origin.key` and `internal-origin.pem`. Cloudflare does not show the
private key again. Restrict the key before doing anything else:

```bash
chmod 600 internal-origin.key
openssl x509 -in internal-origin.pem -noout \
  -subject -issuer -dates -ext subjectAltName
openssl x509 -in internal-origin.pem -noout \
  -checkhost wallet.internal.aoctech.app

CERT_PUBLIC_KEY="$(openssl x509 -in internal-origin.pem -pubkey -noout | \
  openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
PRIVATE_PUBLIC_KEY="$(openssl pkey -in internal-origin.key -pubout -outform DER | \
  sha256sum | awk '{print $1}')"
test "$CERT_PUBLIC_KEY" = "$PRIVATE_PUBLIC_KEY"
```

Upload the two values as encrypted SSM parameters. `file://` prevents placing
the private key contents directly on the command line:

```bash
aws ssm put-parameter \
  --name /ctech/prod/lbalancer/tls/internal-certificate \
  --type SecureString --tier Standard \
  --value file://internal-origin.pem --overwrite
aws ssm put-parameter \
  --name /ctech/prod/lbalancer/tls/internal-private-key \
  --type SecureString --tier Standard \
  --value file://internal-origin.key --overwrite
```

Check metadata without printing either secret:

```bash
aws ssm describe-parameters --parameter-filters \
  'Key=Name,Option=BeginsWith,Values=/ctech/prod/lbalancer/tls/internal-' \
  --query 'Parameters[].{Name:Name,Type:Type,Tier:Tier,Modified:LastModifiedDate}'
```

## 3. Install the Cloudflare Origin CA root in every M2M client

Cloudflare Origin CA is deliberately not in normal operating-system/browser
trust stores. Clients must trust the root matching the certificate key type.
For the RSA choice above on Amazon Linux 2023:

```bash
sudo curl --fail --silent --show-error \
  https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem \
  --output /etc/pki/ca-trust/source/anchors/cloudflare-origin-rsa.pem
sudo chmod 0644 /etc/pki/ca-trust/source/anchors/cloudflare-origin-rsa.pem
sudo update-ca-trust
```

Automate this in each service's immutable bootstrap/CDK; do not perform it only
by hand on the current instance. A client with an application-specific CA pool
can point directly to that PEM instead. Never disable TLS verification.

## 4. Review, deploy, and replace the HAProxy instance

Run these commands from this repository. They do not deploy until the final
`cdk deploy` command:

```bash
npm ci
export ENVIRONMENT=prod
export ENABLE_INTERNAL_M2M=true
export CTECH_VPC_ID="$(aws ssm get-parameter \
  --name /ctech/prod/network/vpc-id \
  --query Parameter.Value --output text)"

npm run build
npm test
npm run synth
npx cdk diff Ctech-Prod-LoadBalancer
npx cdk deploy Ctech-Prod-LoadBalancer --require-approval never
```

The deployment updates the launch template and creates the four private CNAMEs,
but it does not mutate the running EC2 instance. Replace the single ASG member
in a maintenance window:

```bash
REFRESH_ID="$(aws autoscaling start-instance-refresh \
  --auto-scaling-group-name prod-ctech-lbalancer \
  --preferences MinHealthyPercentage=0,InstanceWarmup=600 \
  --query InstanceRefreshId --output text)"
echo "$REFRESH_ID"

aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name prod-ctech-lbalancer \
  --instance-refresh-ids "$REFRESH_ID" \
  --query 'InstanceRefreshes[0].{Status:Status,Percentage:PercentageComplete,Reason:StatusReason}'
```

Because this ASG has one instance, this refresh causes a short public and
private outage while the replacement boots. Do not increase desired capacity
ad hoc: this stack has `maxCapacity=1`, and an unmanaged change would create
drift. A planned two-node HA design should be implemented in CDK first.

## 5. Validate

Get the replacement instance and inspect its local state through SSM:

```bash
INSTANCE_ID="$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names prod-ctech-lbalancer \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)"
aws ssm start-session --target "$INSTANCE_ID"
```

Inside the session:

```bash
sudo systemctl status haproxy ctech-lbalancer-reconcile.timer --no-pager
sudo journalctl -u ctech-lbalancer-reconcile.service -n 100 --no-pager
sudo /usr/local/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg
sudo grep -E '^frontend |^  bind ' /etc/haproxy/haproxy.cfg
sudo nft list table inet ctech_edge
```

Expected binds are `:::443 v6only` for Cloudflare and `0.0.0.0:443` for M2M.
The firewall must show a Cloudflare IPv6 allowlist, the production VPC IPv4
CIDR allow rule, and then the final port-443 drop.

From an internal service instance after installing the RSA root:

```bash
getent ahostsv4 wallet.internal.aoctech.app
openssl s_client \
  -connect wallet.internal.aoctech.app:443 \
  -servername wallet.internal.aoctech.app \
  -CAfile /etc/pki/ca-trust/source/anchors/cloudflare-origin-rsa.pem \
  -verify_return_error </dev/null
curl --fail --show-error --cacert \
  /etc/pki/ca-trust/source/anchors/cloudflare-origin-rsa.pem \
  https://wallet.internal.aoctech.app/v1.0/health-check
```

Also validate `accounts`, `dfe`, and `poker`. From outside the associated VPC,
`wallet.internal.aoctech.app` must not resolve. Finally, verify that a public API
still traverses Cloudflare normally:

```bash
curl --fail --show-error https://wallet-api.aoctech.app/v1.0/health-check
```

## 6. Configure callers

Change only the base URL used by internal callers, for example:

```text
WALLET_BASE_URL=https://wallet.internal.aoctech.app
```

Keep TLS hostname verification enabled, keep the existing M2M application
credential, use bounded connect/request timeouts, and retry only idempotent
operations. The private path avoids Cloudflare but intentionally keeps HAProxy's
load distribution and health-based target removal.

## Future services

Add `internalHostname` to the route registration and create a private CNAME to
`lbalancer.internal.aoctech.app`. The helper does both:

```bash
./scripts/register-route.sh prod billing billing-api.aoctech.app \
  billing.internal.aoctech.app prod-ctech-billing-api 8080 \
  /v1.0/health-check 200,207 true
```

Prefer having the service CDK own both its SSM route parameter and private
CNAME. The operational script is for temporary/manual registrations. When
deregistering a temporary route, also remove its private CNAME.

## Rollback

The fastest non-destructive rollback is to point each M2M client back to its
previous public URL. The public frontend is independent and remains available.

To remove the private frontend and its four managed aliases from infrastructure,
deploy with the feature disabled, then replace the instance again:

```bash
export ENVIRONMENT=prod
export ENABLE_INTERNAL_M2M=false
export CTECH_VPC_ID="$(aws ssm get-parameter \
  --name /ctech/prod/network/vpc-id \
  --query Parameter.Value --output text)"
npx cdk diff Ctech-Prod-LoadBalancer
npx cdk deploy Ctech-Prod-LoadBalancer --require-approval never
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name prod-ctech-lbalancer \
  --preferences MinHealthyPercentage=0,InstanceWarmup=600
```

This does not delete the TLS secrets or the private hosted zone. After rollback,
the runtime-managed `lbalancer.internal.aoctech.app` A record may remain but is
unreachable and has no service aliases. Remove it manually only if the HAProxy
M2M design is permanently retired.

## Certificate rotation

Cloudflare does not currently send expiration notifications for Origin CA
certificates. Record the expiry in monitoring when issuing the certificate and
rotate it before the final 30 days. Upload the new certificate and key to the
same two SSM parameters. Because those writes are separate, the reconciler
keeps the last valid on-disk pair while the new pair is incomplete; after both
values match, the next 30-second reconciliation validates and reloads them.
Re-run the TLS and health checks from section 5 after every rotation.

## Availability and cost

Cloudflare Origin CA is available on the Free plan. This adds no EC2, HAProxy,
SSM Standard Parameter, or per-record Route 53 fee.
It uses the existing HAProxy instance and the already-approved private hosted
zone. Private DNS query charges and normal cross-AZ/data-transfer charges still
apply. Availability remains that of a single HAProxy instance; TTL 10 reduces
DNS recovery delay but cannot remove instance boot time.
