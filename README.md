# ctech-lbalancer

A dual-entrypoint HAProxy intended to replace the shared AWS Application Load
Balancer at the lowest practical AWS cost. Public traffic remains IPv6-only and
Cloudflare-only; private M2M traffic can use VPC IPv4 without Cloudflare.

The stack runs exactly one ARM instance in the existing CTech VPC:

```text
browser -> Cloudflare -> IPv6:443 HAProxy (AOP mTLS) --+
                                                       +-> private IPv4 -> service ASG
service -> private DNS -> IPv4:443 HAProxy ------------+
```

HAProxy is built from the official source tarball as version **3.4.3 LTS** and
verified against its pinned SHA-256. The branch is supported through 2031-Q2.
GitHub Actions compiles the Alpine ARM64 binary in a pinned Alpine Docker build;
the instance only downloads the verified artifact. The instance starts as
`t4g.nano`; `t4g.nano` and `t4g.micro` are supported sizes. It has no public
IPv4 address and uses T4g Standard credits.

## Why HAProxy

For this workload HAProxy is a better fit than Caddy, Traefik, or an nginx plus
scripts combination: it is small, supports active HTTP health checks, HTTP/2,
WebSockets, graceful reloads, mTLS, detailed response counters, and a local
Prometheus endpoint without another daemon. Caddy's automatic public ACME is not
useful for Cloudflare Origin CA certificates; Traefik's control plane costs more
RAM on a nano; open-source nginx needs more care for changing upstream IPs.

## Runtime behavior

- Route registrations are free SSM Standard Parameters under
  `/ctech/{env}/lbalancer/routes/*`.
- The four bootstrap registrations use the current unsuffixed service ASG names
  (`{env}-ctech-{account,dfe,wallet,poker}`), matching the service CDK outputs and
  the deployed production route parameters.
- GitHub Actions compiles each pinned Alpine/ARM64 HAProxy version on a native
  ARM64 runner. The verified bundle is shared across environments in a retained
  S3 bucket; its complete object key is the bundle's SHA-256, recorded in a
  versioned SSM parameter. Instances have read-only artifact access and fail
  bootstrap rather than compiling on the nano if the artifact is unavailable.
- Rendered runtime scripts are also stored under content-addressed keys in the
  existing artifact bucket. EC2 user data only downloads those immutable
  objects, keeping it safely below EC2's 16 KiB limit as the reconciler grows.
- Every 30 seconds the instance discovers all healthy `InService` members of the
  registered Auto Scaling Groups, validates a generated HAProxy config, and
  gracefully reloads only if something changed.
- HAProxy checks each target every five seconds. After three failures it removes
  the target from traffic. When `autoHeal` is true, three failed 30-second
  reconciliations mark the instance unhealthy in its ASG, which replaces it.
- The load balancer is itself a size-one ASG. EC2/system failure replaces it;
  as soon as the replacement HAProxy is listening, it updates the single
  Cloudflare origin AAAA record before running slower auto-heal probes. Failed
  API writes retry every 30 seconds, while successful values are cached locally.
- For the public IPv6 path, `nftables` accepts port 443 only from Cloudflare's
  published ranges.
  HAProxy then requires a zone-specific Authenticated Origin Pull client
  certificate, so both the network source and TLS identity must be Cloudflare.
- In production, `nftables` also accepts port 443 over IPv4 from the VPC CIDR.
  A separate frontend and certificate route `*.internal.aoctech.app`; these
  private names never enter the Cloudflare/public frontend.
- Client IP resolution supports direct API traffic
  (`viewer -> Cloudflare -> HAProxy`) and same-origin frontend API traffic
  (`viewer -> Cloudflare -> CloudFront -> Cloudflare -> HAProxy`). HAProxy starts
  from Cloudflare's authenticated `CF-Connecting-IP` and, only when that address
  belongs to AWS's CloudFront origin-facing ranges, walks the right side of
  `X-Forwarded-For` past the known CloudFront and optional Cloudflare hop. It
  overwrites downstream forwarding headers with the resolved viewer IP, so
  client-supplied entries further left cannot affect audits or rate limits.
- Cloudflare IPv4/IPv6 ranges and AWS's managed CloudFront origin-facing prefix
  list refresh daily. AWS ranges are read through the EC2 dual-stack API because
  the instance has no public IPv4 or NAT. Failed refreshes keep the last valid
  files, while reviewed static fallbacks make first boot deterministic.
- The instance retains the shared edge security group as its identity toward
  backend service SGs and attaches a second, egress-only group for free IPv6
  access to SSM and required internet endpoints.
- Port 80 is intentionally not served. Redirect HTTP to HTTPS at Cloudflare.

## Important domain distinction

The existing repositories use `poker.aoctech.app`, `accounts.aoctech.app`, and
`wallet.aoctech.app` for CloudFront/S3 frontends. Their API origins are
`poker-api.aoctech.app`, `accounts-api.aoctech.app`, and
`wallet-api.aoctech.app`. The default registrations route those API names plus
the existing `dfe-api.aoctech.app` origin. Pointing the three UI names straight
at HAProxy today would break their
static frontend behaviors.

If the intention is also to retire CloudFront, that is a separate migration:
HAProxy would need a static origin (or each frontend would need to be hosted on
its service instance) before those names can move.

## Deploy

This repo is managed with Terraform (migrated from CDK). Prerequisites:
Terraform >= 1.15, AWS CLI credentials (`--profile ctech`), the existing
dual-stack CTech VPC, and the TLS parameters described in
[docs/operations.md](docs/operations.md). Certificate renewal and CA rollover
are documented separately in
[docs/aop-certificate-renewal.md](docs/aop-certificate-renewal.md).
Private M2M prerequisites, deployment, client trust, validation, and rollback
are in [docs/internal-m2m.md](docs/internal-m2m.md).

One-time setup, per AWS account: `./scripts/bootstrap-terraform-state.sh`
creates the shared Terraform state bucket used by all roots below.

```bash
# 1. Account/region-wide artifact bucket — deploy once, independent of environment.
cd terraform/artifact
terraform init
terraform apply

# 2. GitHub OIDC publisher — deploy once from a trusted workstation.
# The shared OIDC provider must already exist at /ctech/global/oidc/provider-arn.
cd ../github
AWS_PROFILE=ctech terraform init
AWS_PROFILE=ctech terraform apply

# 3. Merge or manually run "HAProxy ARM64 Artifact" on main, and wait for it
# to publish the Alpine artifact before creating/replacing an Alpine instance.

# 4. Per-environment load balancer stack.
# No baked-in backend profile — export AWS_PROFILE for workstation runs
# (CI uses short-lived OIDC credentials via .github/workflows/lbalancer.yml).
cd ../lbalancer
export AWS_PROFILE=ctech
terraform init
terraform workspace select prod || terraform workspace new prod
terraform plan  -var-file=environments/prod.tfvars
terraform apply -var-file=environments/prod.tfvars
```

`environments/{dev,stage,prod}.tfvars` holds `vpc_id` (read from
`/ctech/{env}/network/vpc-id`), `instance_type`, and `enable_internal_m2m` per
environment. All three Terraform directories are independent roots with
separate state. The artifact bucket has no expiration rule and no public access.
The branch-restricted GitHub OIDC role can publish Alpine artifacts and their
versioned pointers; Alpine instances can only read them. AL2023 retains its
legacy on-instance artifact-cache publisher until that boot path is retired.

The ALB migration is complete: nothing in this account instantiates an ALB and
the production account has no ELBv2 load balancer. `origin.aoctech.app`
is the DNS-only AAAA maintained by this stack; proxied `*-api` CNAMEs point to it.

After the EC2 free tier:

```bash
terraform apply -var-file=environments/prod.tfvars -var='instance_type=t4g.nano'
```

## Register a future service

No central CDK change is required. Its service CDK should create one Standard
SSM parameter containing this shape:

```json
{
  "hostname": "billing-api.aoctech.app",
  "internalHostname": "billing.internal.aoctech.app",
  "asg": "prod-ctech-billing-api",
  "port": 8080,
  "healthPath": "/v1.0/health-check",
  "healthyStatuses": [
    200,
    207
  ],
  "autoHeal": true
}
```

In a TypeScript service CDK that is simply:

```typescript
new ssm.StringParameter(this, 'LoadBalancerRoute', {
  parameterName: `/ctech/${environment}/lbalancer/routes/billing`,
  tier: ssm.ParameterTier.STANDARD,
  stringValue: JSON.stringify({
    hostname: domainName,
    internalHostname: `billing${environment === 'prod' ? '' : `-${environment}`}.internal.aoctech.app`,
    asg: apiAsgName,
    port: 8080,
    healthPath: '/v1.0/health-check',
    healthyStatuses: [200, 207],
    autoHeal: true,
  }),
});
```

The same service stack should own its private alias:

```typescript
const privateZone = route53.HostedZone.fromHostedZoneAttributes(this, 'PrivateZone', {
  hostedZoneId: ssm.StringParameter.valueForStringParameter(
    this,
    '/ctech/global/dns/private-hosted-zone-id',
  ),
  zoneName: 'internal.aoctech.app',
});
new route53.CnameRecord(this, 'LoadBalancerInternalAlias', {
  zone: privateZone,
  recordName: `billing${environment === 'prod' ? '' : `-${environment}`}`,
  domainName: 'lbalancer.internal.aoctech.app',
  ttl: cdk.Duration.seconds(30),
});
```

For an operational registration without a service-CDK release:

```bash
./scripts/register-route.sh prod billing billing-api.aoctech.app \
  billing.internal.aoctech.app prod-ctech-billing-api 8080 \
  /v1.0/health-check 200,207 true
```

Also create a proxied Cloudflare CNAME from `billing-api.aoctech.app` to
`origin.aoctech.app`. The origin AAAA remains DNS-only and is maintained by the
load balancer. The helper above also creates the private CNAME; service CDK
should own it for permanent routes. The service security group must allow its port from the shared
edge SG; current services already do this because that SG is the former ALB SG.

## Logs and metrics

The lowest-overhead inspection path is local HAProxy observability:

```bash
aws ssm start-session --target INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8404"],"localPortNumber":["8404"]}'
```

Open `http://127.0.0.1:8404/stats` or scrape `/metrics`. HAProxy exposes 2xx,
3xx, 4xx, and 5xx counters by frontend/backend/server at no AWS metric cost.

CloudWatch log streaming is enabled by default. HAProxy JSON access events and
reconciler diagnostics are sent to
`/ctech-lbalancer/{env}/access`, with 30-day retention in production and 7 days
elsewhere. Alpine uses the lightweight, AMI-embedded
`ctech-ec2-agent logs-tail` path already used by `ctech-billing`; the legacy
AL2023 path uses the standard `amazon-cloudwatch-agent`.

No custom CloudWatch metrics are created in the frugal phase. Request/status
and latency aggregations can be queried from the structured logs or read from
HAProxy's local Prometheus endpoint without the fixed per-series cost.

## Cost envelope (us-east-1, 730-hour month)

| Item                             |       During free tier | After free tier |
|----------------------------------|-----------------------:|----------------:|
| t4g.nano / t4g.nano             | eligible / about $6.13 |     about $3.07 |
| 4 GB gp3 root disk               |            about $0.32 |     about $0.32 |
| public IPv4                      |                     $0 |              $0 |
| SSM Standard Parameters          |                     $0 |              $0 |
| existing private hosted zone     |          about $0.50/mo |   about $0.50/mo |
| HAProxy S3 artifact              |                 <$0.01 |          <$0.01 |
| local stats/Prometheus           |                     $0 |              $0 |
| CloudWatch custom metrics        |                     $0 |              $0 |

CloudWatch Logs storage/ingestion is usage-based and therefore not included as
a fixed monthly line item. Disable it with `enable_cloudwatch_logs = false` if
local-only observability is preferable in a temporary environment.

The ALB base fee alone is about $16.43/month before LCU usage. Normal EC2 data
transfer still applies. Cross-AZ backend traffic can add regional transfer cost;
at this workload's expected volume it should be small, but it must be watched.
T4g Standard does not incur surplus-credit charges; instead it throttles after
the credit balance is exhausted. `CPUCreditBalance`, memory, boot duration, and
HAProxy latency must all be checked before changing to nano.

## Availability trade-off

This saves money by giving up multi-AZ simultaneous edge capacity. The size-one
ASG automatically recovers, but replacement plus Cloudflare origin-DNS refresh
can produce several minutes of 52x responses. Keeping two instances or an AWS
load balancer removes that gap and also removes most of the savings. This stack
makes the single-node trade explicitly because cost is the primary constraint.
