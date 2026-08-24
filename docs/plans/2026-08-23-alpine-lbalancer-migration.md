# Alpine AMI Migration for ctech-lbalancer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `ctech-lbalancer` a `var.os_family = "alpine"` boot path that swaps AL2023 for ctech-cdk's custom Alpine ARM64 AMI, with `"al2023"` staying the default and unchanged.

**Architecture:** Two repos. `ctech-cdk` (Go) gains five `ctech-ec2-agent` subcommands the Alpine shell scripts need in place of `aws-cli` — this is a hard dependency, done first (Tasks 1-6). `ctech-lbalancer` (Terraform) then gains three new `*-alpine.sh.tftpl` templates (ports of the existing `bootstrap`/`reconcile`/`refresh-cloudflare-ips` scripts to `apk`/OpenRC/`ctech-ec2-agent`) and a `var.os_family` toggle that branches `image_id`, three `templatefile()` calls, and `block_device_mappings.volume_size` in `compute.tf` (Tasks 7-13). No existing `.tftpl` file is renamed or rewritten. Task 14 covers the two live-verification gaps the spec calls out (`logrotate`, the supervised reconcile loop) plus a full boot test. Every `terraform apply`/`packer build`/AWS CLI command in this plan is run by the user, never by the implementing agent — no AWS credentials are available in-session.

**Tech Stack:** Go 1.26 + aws-sdk-go-v2 (`ctech-ec2-agent`), Terraform 1.15 + AWS provider 6.x, bash/OpenRC/apk (Alpine 3.23), HAProxy 3.4.3 compiled `TARGET=linux-musl`.

**Spec:** `docs/specs/2026-08-23-alpine-lbalancer-migration.md`

## Global Constraints

- `os_family` accepts exactly `"al2023"` (default) or `"alpine"` — no other value, validated.
- No existing file (`bootstrap.sh.tftpl`, `reconcile.sh.tftpl`, `refresh-cloudflare-ips.sh.tftpl`, and every AL2023 branch of `compute.tf`/`variables.tf`/`data.tf`/`iam.tf`) is modified in behavior — only new, additive, `os_family`-gated code.
- HAProxy on Alpine is compiled from source with `TARGET=linux-musl USE_OPENSSL=1 USE_PCRE2=1 USE_ZLIB=1 USE_PROMEX=1` — never the `apk add haproxy` package (loses Prometheus exporter support, unverified).
- Alpine root volume is `1` GiB (`4` GiB stays for AL2023); swap is a hard `128` MiB, not `256` — verified live to be the largest size that still leaves room for the HAProxy build.
- Every new `ctech-ec2-agent` subcommand that returns AWS API data emits the same JSON shape (field names in AWS-CLI-`--output json` casing) so the Alpine shell scripts' `jq` filters are byte-identical to the AL2023 scripts' filters wherever the underlying data is unchanged.
- No `terraform apply`, `packer build`, or `aws` CLI command against real infrastructure is run by the agent implementing this plan — hand the exact command to the user each time and wait for their result.

---

## Part 1 — ctech-cdk: five new `ctech-ec2-agent` subcommands

Repo: `~/Documents/Projects/Ctech/ctech-cdk`. Read `assets/ctech-ec2-agent/main.go`, `ssm.go`, and `s3.go` before starting — every task below follows their existing pattern exactly (a `parseXArgs` function returning a typed args struct, a `newXClient` helper that calls `config.LoadDefaultConfig(ctx, config.WithEC2IMDSRegion())`, a `runX` function, wired into `main.go`'s `switch`). This part blocks every Part 2 task: `ctech-lbalancer`'s new `-alpine.sh.tftpl` scripts call these subcommands by name.

### Task 1: `ssm-get-by-path` subcommand

**Files:**
- Modify: `assets/ctech-ec2-agent/ssm.go` (add to the existing file — same `ssm.Client`, same service)
- Test: `assets/ctech-ec2-agent/ssm_test.go` (add to the existing file)

**Interfaces:**
- Consumes: `newSSMClient(ctx)` (already defined in `ssm.go:51-59`)
- Produces: `runSSMGetByPath(ctx context.Context, argv []string) error`, registered in `main.go` as case `"ssm-get-by-path"`. Prints `{"Parameters":[{"Name":"...","Value":"..."}]}` to stdout — the same top-level shape `aws ssm get-parameters-by-path --output json` produces, so `reconcile-alpine.sh.tftpl` (Task 11) can reuse `jq -ce '[.Parameters[].Value | fromjson]'` unchanged from `reconcile.sh.tftpl`.

- [ ] **Step 1: Write the failing test**

Add to `assets/ctech-ec2-agent/ssm_test.go`:

```go
func TestParseSSMGetByPathArgsRequiresPath(t *testing.T) {
	if _, err := parseSSMGetByPathArgs([]string{}); err == nil {
		t.Fatal("expected an error when -path is missing")
	}
}

func TestParseSSMGetByPathArgsDefaultsToDecrypt(t *testing.T) {
	args, err := parseSSMGetByPathArgs([]string{"-path", "/ctech/prod/lbalancer/routes"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if args.path != "/ctech/prod/lbalancer/routes" {
		t.Fatalf("path = %q, want /ctech/prod/lbalancer/routes", args.path)
	}
	if !args.decrypt {
		t.Fatal("decrypt should default to true")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assets/ctech-ec2-agent && go test ./... -run TestParseSSMGetByPath -v`
Expected: FAIL with `undefined: parseSSMGetByPathArgs`

- [ ] **Step 3: Write minimal implementation**

Add to `assets/ctech-ec2-agent/ssm.go`:

```go
type ssmGetByPathArgs struct {
	path    string
	decrypt bool
}

func parseSSMGetByPathArgs(args []string) (ssmGetByPathArgs, error) {
	fs := flag.NewFlagSet("ssm-get-by-path", flag.ContinueOnError)
	path := fs.String("path", "", "SSM parameter path prefix")
	decrypt := fs.Bool("decrypt", true, "decrypt SecureString parameters")
	if err := fs.Parse(args); err != nil {
		return ssmGetByPathArgs{}, err
	}
	if *path == "" {
		return ssmGetByPathArgs{}, fmt.Errorf("-path is required")
	}
	return ssmGetByPathArgs{path: *path, decrypt: *decrypt}, nil
}

type ssmParameterOutput struct {
	Name  string `json:"Name"`
	Value string `json:"Value"`
}

type ssmParametersByPathOutput struct {
	Parameters []ssmParameterOutput `json:"Parameters"`
}

// runSSMGetByPath mirrors `aws ssm get-parameters-by-path --recursive --output
// json`'s top-level shape exactly, so reconcile-alpine.sh.tftpl's jq filter
// needs no change from reconcile.sh.tftpl's.
func runSSMGetByPath(ctx context.Context, argv []string) error {
	args, err := parseSSMGetByPathArgs(argv)
	if err != nil {
		return err
	}
	client, err := newSSMClient(ctx)
	if err != nil {
		return err
	}
	out := ssmParametersByPathOutput{Parameters: []ssmParameterOutput{}}
	paginator := ssm.NewGetParametersByPathPaginator(client, &ssm.GetParametersByPathInput{
		Path:           aws.String(args.path),
		Recursive:      aws.Bool(true),
		WithDecryption: aws.Bool(args.decrypt),
	})
	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return fmt.Errorf("get parameters by path %q: %w", args.path, err)
		}
		for _, p := range page.Parameters {
			out.Parameters = append(out.Parameters, ssmParameterOutput{
				Name:  aws.ToString(p.Name),
				Value: aws.ToString(p.Value),
			})
		}
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}
```

Add `"encoding/json"` to `ssm.go`'s import block (`os` is already imported there).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assets/ctech-ec2-agent && go test ./... -run TestParseSSMGetByPath -v`
Expected: PASS

- [ ] **Step 5: Wire into `main.go`, build, commit**

Add to `main.go`'s `switch` (after the `"ssm-put"` case):

```go
	case "ssm-get-by-path":
		err = runSSMGetByPath(ctx, args)
```

Run: `cd assets/ctech-ec2-agent && go build ./... && go vet ./...`
Expected: no errors

```bash
git add assets/ctech-ec2-agent/ssm.go assets/ctech-ec2-agent/ssm_test.go assets/ctech-ec2-agent/main.go
git commit -m "feat(ctech-ec2-agent): add ssm-get-by-path subcommand"
```

### Task 2: `asg-describe` subcommand

**Files:**
- Create: `assets/ctech-ec2-agent/asg.go`
- Create: `assets/ctech-ec2-agent/asg_test.go`

**Interfaces:**
- Produces: `runASGDescribe(ctx context.Context, argv []string) error`, registered as case `"asg-describe"`. Prints `{"AutoScalingGroups":[{"AutoScalingGroupName":"...","Instances":[{"InstanceId":"...","LifecycleState":"...","HealthStatus":"..."}]}]}` — same shape `aws autoscaling describe-auto-scaling-groups --output json` produces (trimmed to the three fields `reconcile.sh.tftpl`'s jq filters actually read). Also produces `newASGClient(ctx context.Context) (*autoscaling.Client, error)`, reused by Task 4.

- [ ] **Step 1: Write the failing test**

Create `assets/ctech-ec2-agent/asg_test.go`:

```go
package main

import "testing"

func TestParseASGDescribeArgsRequiresNames(t *testing.T) {
	if _, err := parseASGDescribeArgs([]string{}); err == nil {
		t.Fatal("expected an error when -names is missing")
	}
}

func TestParseASGDescribeArgsSplitsOnComma(t *testing.T) {
	args, err := parseASGDescribeArgs([]string{"-names", "prod-ctech-account,prod-ctech-dfe"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"prod-ctech-account", "prod-ctech-dfe"}
	if len(args.names) != len(want) || args.names[0] != want[0] || args.names[1] != want[1] {
		t.Fatalf("names = %v, want %v", args.names, want)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assets/ctech-ec2-agent && go test ./... -run TestParseASGDescribe -v`
Expected: FAIL with `undefined: parseASGDescribeArgs`

- [ ] **Step 3: Write minimal implementation**

First: `cd assets/ctech-ec2-agent && go get github.com/aws/aws-sdk-go-v2/service/autoscaling && go mod tidy`

Create `assets/ctech-ec2-agent/asg.go`:

```go
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/autoscaling"
)

func newASGClient(ctx context.Context) (*autoscaling.Client, error) {
	cfg, err := config.LoadDefaultConfig(ctx, config.WithEC2IMDSRegion())
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}
	return autoscaling.NewFromConfig(cfg), nil
}

type asgDescribeArgs struct {
	names []string
}

func parseASGDescribeArgs(argv []string) (asgDescribeArgs, error) {
	fs := flag.NewFlagSet("asg-describe", flag.ContinueOnError)
	names := fs.String("names", "", "comma-separated auto scaling group names")
	if err := fs.Parse(argv); err != nil {
		return asgDescribeArgs{}, err
	}
	if *names == "" {
		return asgDescribeArgs{}, fmt.Errorf("-names is required")
	}
	return asgDescribeArgs{names: strings.Split(*names, ",")}, nil
}

type asgInstanceOutput struct {
	InstanceID     string `json:"InstanceId"`
	LifecycleState string `json:"LifecycleState"`
	HealthStatus   string `json:"HealthStatus"`
}

type autoScalingGroupOutput struct {
	AutoScalingGroupName string              `json:"AutoScalingGroupName"`
	Instances            []asgInstanceOutput `json:"Instances"`
}

type describeASGOutput struct {
	AutoScalingGroups []autoScalingGroupOutput `json:"AutoScalingGroups"`
}

// runASGDescribe mirrors `aws autoscaling describe-auto-scaling-groups
// --output json`'s shape (trimmed to the fields reconcile.sh's jq filters
// read), so reconcile-alpine.sh.tftpl's filters are unchanged.
func runASGDescribe(ctx context.Context, argv []string) error {
	args, err := parseASGDescribeArgs(argv)
	if err != nil {
		return err
	}
	client, err := newASGClient(ctx)
	if err != nil {
		return err
	}
	result, err := client.DescribeAutoScalingGroups(ctx, &autoscaling.DescribeAutoScalingGroupsInput{
		AutoScalingGroupNames: args.names,
	})
	if err != nil {
		return fmt.Errorf("describe auto scaling groups %v: %w", args.names, err)
	}
	out := describeASGOutput{AutoScalingGroups: []autoScalingGroupOutput{}}
	for _, g := range result.AutoScalingGroups {
		group := autoScalingGroupOutput{
			AutoScalingGroupName: aws.ToString(g.AutoScalingGroupName),
			Instances:            []asgInstanceOutput{},
		}
		for _, i := range g.Instances {
			group.Instances = append(group.Instances, asgInstanceOutput{
				InstanceID:     aws.ToString(i.InstanceId),
				LifecycleState: string(i.LifecycleState),
				HealthStatus:   aws.ToString(i.HealthStatus),
			})
		}
		out.AutoScalingGroups = append(out.AutoScalingGroups, group)
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assets/ctech-ec2-agent && go test ./... -run TestParseASGDescribe -v`
Expected: PASS

- [ ] **Step 5: Wire into `main.go`, build, commit**

Add to `main.go`'s `switch`:

```go
	case "asg-describe":
		err = runASGDescribe(ctx, args)
```

Run: `cd assets/ctech-ec2-agent && go build ./... && go vet ./...`

```bash
git add assets/ctech-ec2-agent/asg.go assets/ctech-ec2-agent/asg_test.go assets/ctech-ec2-agent/main.go assets/ctech-ec2-agent/go.mod assets/ctech-ec2-agent/go.sum
git commit -m "feat(ctech-ec2-agent): add asg-describe subcommand"
```

### Task 3: `ec2-describe-instances` subcommand

**Files:**
- Create: `assets/ctech-ec2-agent/ec2instances.go`
- Create: `assets/ctech-ec2-agent/ec2instances_test.go`

**Interfaces:**
- Consumes: nothing new — `ec2` is already a dependency (`prefixlist.go`).
- Produces: `runEC2DescribeInstances(ctx context.Context, argv []string) error`, registered as case `"ec2-describe-instances"`. Prints `{"Reservations":[{"Instances":[{"InstanceId":"...","PrivateIpAddress":"...","State":{"Name":"..."},"LaunchTime":"2026-08-23T18:00:00Z"}]}]}` (RFC 3339 `LaunchTime`, parseable by `date -d` exactly like the AWS CLI's ISO 8601 output).

- [ ] **Step 1: Write the failing test**

Create `assets/ctech-ec2-agent/ec2instances_test.go`:

```go
package main

import "testing"

func TestParseEC2DescribeInstancesArgsRequiresIDs(t *testing.T) {
	if _, err := parseEC2DescribeInstancesArgs([]string{}); err == nil {
		t.Fatal("expected an error when -ids is missing")
	}
}

func TestParseEC2DescribeInstancesArgsSplitsOnComma(t *testing.T) {
	args, err := parseEC2DescribeInstancesArgs([]string{"-ids", "i-aaa,i-bbb"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(args.ids) != 2 || args.ids[0] != "i-aaa" || args.ids[1] != "i-bbb" {
		t.Fatalf("ids = %v, want [i-aaa i-bbb]", args.ids)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assets/ctech-ec2-agent && go test ./... -run TestParseEC2DescribeInstances -v`
Expected: FAIL with `undefined: parseEC2DescribeInstancesArgs`

- [ ] **Step 3: Write minimal implementation**

Create `assets/ctech-ec2-agent/ec2instances.go`:

```go
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
)

type ec2DescribeInstancesArgs struct {
	ids []string
}

func parseEC2DescribeInstancesArgs(argv []string) (ec2DescribeInstancesArgs, error) {
	fs := flag.NewFlagSet("ec2-describe-instances", flag.ContinueOnError)
	ids := fs.String("ids", "", "comma-separated instance ids")
	if err := fs.Parse(argv); err != nil {
		return ec2DescribeInstancesArgs{}, err
	}
	if *ids == "" {
		return ec2DescribeInstancesArgs{}, fmt.Errorf("-ids is required")
	}
	return ec2DescribeInstancesArgs{ids: strings.Split(*ids, ",")}, nil
}

type instanceStateOutput struct {
	Name string `json:"Name"`
}

type ec2InstanceOutput struct {
	InstanceID       string              `json:"InstanceId"`
	PrivateIPAddress string              `json:"PrivateIpAddress"`
	State            instanceStateOutput `json:"State"`
	LaunchTime       string              `json:"LaunchTime"`
}

type reservationOutput struct {
	Instances []ec2InstanceOutput `json:"Instances"`
}

type describeInstancesOutput struct {
	Reservations []reservationOutput `json:"Reservations"`
}

// runEC2DescribeInstances mirrors `aws ec2 describe-instances --output
// json`'s shape (trimmed to the fields reconcile.sh's jq filters read), so
// reconcile-alpine.sh.tftpl's filters are unchanged. LaunchTime is RFC 3339,
// same as the AWS CLI's JSON output — `date -d` parses both identically.
func runEC2DescribeInstances(ctx context.Context, argv []string) error {
	args, err := parseEC2DescribeInstancesArgs(argv)
	if err != nil {
		return err
	}
	cfg, err := config.LoadDefaultConfig(ctx, config.WithEC2IMDSRegion())
	if err != nil {
		return fmt.Errorf("load AWS config: %w", err)
	}
	client := ec2.NewFromConfig(cfg)
	result, err := client.DescribeInstances(ctx, &ec2.DescribeInstancesInput{
		InstanceIds: args.ids,
	})
	if err != nil {
		return fmt.Errorf("describe instances %v: %w", args.ids, err)
	}
	out := describeInstancesOutput{Reservations: []reservationOutput{}}
	for _, r := range result.Reservations {
		reservation := reservationOutput{Instances: []ec2InstanceOutput{}}
		for _, i := range r.Instances {
			launchTime := ""
			if i.LaunchTime != nil {
				launchTime = i.LaunchTime.Format(time.RFC3339)
			}
			reservation.Instances = append(reservation.Instances, ec2InstanceOutput{
				InstanceID:       aws.ToString(i.InstanceId),
				PrivateIPAddress: aws.ToString(i.PrivateIpAddress),
				State:            instanceStateOutput{Name: string(i.State.Name)},
				LaunchTime:       launchTime,
			})
		}
		out.Reservations = append(out.Reservations, reservation)
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assets/ctech-ec2-agent && go test ./... -run TestParseEC2DescribeInstances -v`
Expected: PASS

- [ ] **Step 5: Wire into `main.go`, build, commit**

Add to `main.go`'s `switch`:

```go
	case "ec2-describe-instances":
		err = runEC2DescribeInstances(ctx, args)
```

Run: `cd assets/ctech-ec2-agent && go build ./... && go vet ./...`

```bash
git add assets/ctech-ec2-agent/ec2instances.go assets/ctech-ec2-agent/ec2instances_test.go assets/ctech-ec2-agent/main.go
git commit -m "feat(ctech-ec2-agent): add ec2-describe-instances subcommand"
```

### Task 4: `asg-set-unhealthy` subcommand

**Files:**
- Modify: `assets/ctech-ec2-agent/asg.go` (reuses `newASGClient` from Task 2)
- Modify: `assets/ctech-ec2-agent/asg_test.go`

**Interfaces:**
- Consumes: `newASGClient(ctx)` from Task 2.
- Produces: `runASGSetUnhealthy(ctx context.Context, argv []string) error`, registered as case `"asg-set-unhealthy"`. No stdout output; a non-nil error means the call failed.

- [ ] **Step 1: Write the failing test**

Add to `assets/ctech-ec2-agent/asg_test.go`:

```go
func TestParseASGSetUnhealthyArgsRequiresInstanceID(t *testing.T) {
	if _, err := parseASGSetUnhealthyArgs([]string{}); err == nil {
		t.Fatal("expected an error when -instance-id is missing")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assets/ctech-ec2-agent && go test ./... -run TestParseASGSetUnhealthy -v`
Expected: FAIL with `undefined: parseASGSetUnhealthyArgs`

- [ ] **Step 3: Write minimal implementation**

Add to `assets/ctech-ec2-agent/asg.go`:

```go
type asgSetUnhealthyArgs struct {
	instanceID string
}

func parseASGSetUnhealthyArgs(argv []string) (asgSetUnhealthyArgs, error) {
	fs := flag.NewFlagSet("asg-set-unhealthy", flag.ContinueOnError)
	instanceID := fs.String("instance-id", "", "instance id to mark Unhealthy")
	if err := fs.Parse(argv); err != nil {
		return asgSetUnhealthyArgs{}, err
	}
	if *instanceID == "" {
		return asgSetUnhealthyArgs{}, fmt.Errorf("-instance-id is required")
	}
	return asgSetUnhealthyArgs{instanceID: *instanceID}, nil
}

// runASGSetUnhealthy always respects the ASG's health-check grace period —
// reconcile.sh's own auto-heal logic already waits out a 3-minute launch
// guard (`$((now - launched)) -ge 180`) before ever calling this, so a second
// grace period here only ever adds delay, never skips the check.
func runASGSetUnhealthy(ctx context.Context, argv []string) error {
	args, err := parseASGSetUnhealthyArgs(argv)
	if err != nil {
		return err
	}
	client, err := newASGClient(ctx)
	if err != nil {
		return err
	}
	_, err = client.SetInstanceHealth(ctx, &autoscaling.SetInstanceHealthInput{
		InstanceId:                  aws.String(args.instanceID),
		HealthStatus:                aws.String("Unhealthy"),
		ShouldRespectGracePeriod:    aws.Bool(true),
	})
	if err != nil {
		return fmt.Errorf("set instance %s unhealthy: %w", args.instanceID, err)
	}
	return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assets/ctech-ec2-agent && go test ./... -run TestParseASGSetUnhealthy -v`
Expected: PASS

- [ ] **Step 5: Wire into `main.go`, build, commit**

Add to `main.go`'s `switch`:

```go
	case "asg-set-unhealthy":
		err = runASGSetUnhealthy(ctx, args)
```

Run: `cd assets/ctech-ec2-agent && go build ./... && go vet ./... && go test ./...`
Expected: all pass

```bash
git add assets/ctech-ec2-agent/asg.go assets/ctech-ec2-agent/asg_test.go assets/ctech-ec2-agent/main.go
git commit -m "feat(ctech-ec2-agent): add asg-set-unhealthy subcommand"
```

### Task 5: `s3-put` subcommand

**Files:**
- Modify: `assets/ctech-ec2-agent/s3.go` (reuses `newS3Client`)
- Modify: `assets/ctech-ec2-agent/s3_test.go`

**Interfaces:**
- Consumes: `newS3Client(ctx)` (`s3.go:54-62`).
- Produces: `runS3Put(ctx context.Context, argv []string) error`, registered as case `"s3-put"`. No stdout output.

- [ ] **Step 1: Write the failing test**

Add to `assets/ctech-ec2-agent/s3_test.go`:

```go
func TestParseS3PutArgsRequiresAllFields(t *testing.T) {
	if _, err := parseS3PutArgs([]string{"-bucket", "b", "-key", "k"}); err == nil {
		t.Fatal("expected an error when -file is missing")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assets/ctech-ec2-agent && go test ./... -run TestParseS3PutArgs -v`
Expected: FAIL with `undefined: parseS3PutArgs`

- [ ] **Step 3: Write minimal implementation**

Add to `assets/ctech-ec2-agent/s3.go` (needs `s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"` added to the import block):

```go
type s3PutArgs struct {
	bucket, key, file string
}

func parseS3PutArgs(argv []string) (s3PutArgs, error) {
	fs := flag.NewFlagSet("s3-put", flag.ContinueOnError)
	bucket := fs.String("bucket", "", "destination bucket")
	key := fs.String("key", "", "destination object key")
	file := fs.String("file", "", "local source file")
	if err := fs.Parse(argv); err != nil {
		return s3PutArgs{}, err
	}
	if *bucket == "" || *key == "" || *file == "" {
		return s3PutArgs{}, fmt.Errorf("-bucket, -key and -file are required")
	}
	return s3PutArgs{bucket: *bucket, key: *key, file: *file}, nil
}

// runS3Put always requests a SHA-256 checksum: this exists specifically for
// bootstrap-alpine.sh.tftpl's HAProxy artifact cache, which is keyed by its
// SHA-256 digest — the same reason the AL2023 script's aws s3api put-object
// call always passes --checksum-algorithm SHA256.
func runS3Put(ctx context.Context, argv []string) error {
	args, err := parseS3PutArgs(argv)
	if err != nil {
		return err
	}
	client, err := newS3Client(ctx)
	if err != nil {
		return err
	}
	f, err := os.Open(args.file)
	if err != nil {
		return fmt.Errorf("open %s: %w", args.file, err)
	}
	defer f.Close()

	_, err = client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:            aws.String(args.bucket),
		Key:               aws.String(args.key),
		Body:              f,
		ChecksumAlgorithm: s3types.ChecksumAlgorithmSha256,
	})
	if err != nil {
		return fmt.Errorf("put s3://%s/%s: %w", args.bucket, args.key, err)
	}
	return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assets/ctech-ec2-agent && go test ./... -run TestParseS3PutArgs -v`
Expected: PASS

- [ ] **Step 5: Wire into `main.go`, build, commit**

Add to `main.go`'s `switch`:

```go
	case "s3-put":
		err = runS3Put(ctx, args)
```

Run: `cd assets/ctech-ec2-agent && go build ./... && go vet ./... && go test ./...`
Expected: all pass

```bash
git add assets/ctech-ec2-agent/s3.go assets/ctech-ec2-agent/s3_test.go assets/ctech-ec2-agent/main.go
git commit -m "feat(ctech-ec2-agent): add s3-put subcommand"
```

### Task 6: full local verification, CLAUDE.md update, and cross-repo handoff note

**Files:**
- Modify: `CLAUDE.md` (the "Published package" / `ctech-ec2-agent` subcommand list under "Alpine AMI pipeline (staged)")

**Interfaces:** none new — this task only verifies Tasks 1-5 together and documents the result.

- [ ] **Step 1: Run the full test suite and build**

Run: `cd assets/ctech-ec2-agent && go build ./... && go vet ./... && go test ./... -v`
Expected: all tests pass, binary builds

- [ ] **Step 2: Run the repo-wide checks CLAUDE.md requires for any change here**

Run: `cd ~/Documents/Projects/Ctech/ctech-cdk && npm test && npx tsc --noEmit`
Expected: 64+ tests pass (existing suite, unaffected by this Go-only change — confirms nothing in the TypeScript side references the removed/added subcommand list in a way that broke)

- [ ] **Step 3: Update CLAUDE.md**

In the "Alpine AMI pipeline (staged)" section, extend the `ctech-ec2-agent` subcommand list (currently ending in `logs-tail`) to also mention: `ssm-get-by-path`, `asg-describe`, `ec2-describe-instances`, `asg-set-unhealthy`, `s3-put` — added for `ctech-lbalancer`'s Alpine migration (a separate repo, see its own `docs/plans/2026-08-23-alpine-lbalancer-migration.md`), each a straight subcommand-per-operation port of one `aws-cli` call `ctech-lbalancer`'s reconcile/bootstrap scripts already made.

- [ ] **Step 4: Commit the doc update**

```bash
git add CLAUDE.md
git commit -m "docs: document five new ctech-ec2-agent subcommands for ctech-lbalancer"
```

- [ ] **Step 5: Tell the user the cross-repo dependency is clear to proceed**

State explicitly: Part 2 (`ctech-lbalancer`) can now be implemented against these five subcommands' final flag names. The actual `ctech-ec2-agent` binary that ships inside a real AMI is only rebuilt the next time `ctech-cdk`'s CI runs (`.github/workflows/ctech-cdk.yml`, before every `cdk diff`/`cdk deploy`) and only takes effect in a `ctech-lbalancer` instance after the next Alpine AMI Packer build (`.github/workflows/build-alpine-ami.yml`) and the next `terraform apply` — Part 2's Task 14 (live boot verification) cannot run until that chain has completed at least once. This is the user's call to trigger, not the agent's.

---

## Part 2 — ctech-lbalancer: the `os_family` toggle

Repo: `~/Documents/Projects/Ctech/ctech-lbalancer`. No `.tftpl`, `.tf`, or Go test framework exists in this repo — "tests" here are `bash -n` (shell syntax), `terraform validate` (HCL correctness, no AWS calls, no credentials needed), and — for Task 14 only — a live boot on a real instance the user runs. `terraform plan`/`apply` need the S3 backend (real AWS credentials) and are always run by the user, never the agent.

### Task 7: `var.os_family`

**Files:**
- Modify: `terraform/lbalancer/variables.tf`

**Interfaces:**
- Produces: `var.os_family`, consumed by Tasks 8, 9-11 (indirectly, via Task 12), 12, and 13.

- [ ] **Step 1: Add the variable**

Append to `terraform/lbalancer/variables.tf`:

```hcl
variable "os_family" {
  type    = string
  default = "al2023"
  validation {
    condition     = contains(["al2023", "alpine"], var.os_family)
    error_message = "os_family must be al2023 or alpine."
  }
}
```

- [ ] **Step 2: Validate**

Run: `cd terraform/lbalancer && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add terraform/lbalancer/variables.tf
git commit -m "feat(lbalancer): add os_family variable, defaulting to al2023"
```

### Task 8: Alpine AMI and script-bucket data sources

**Files:**
- Modify: `terraform/lbalancer/data.tf`

**Interfaces:**
- Consumes: `var.os_family` (Task 7).
- Produces: `data.aws_ssm_parameter.alpine_arm64_ami[0].value`, `data.aws_ssm_parameter.ec2_scripts_alpine_bucket[0].value`, `data.aws_ssm_parameter.ec2_scripts_alpine_version[0].value` — all `count`-gated on `var.os_family == "alpine"`, consumed by Task 12.

- [ ] **Step 1: Add the data sources**

Append to `terraform/lbalancer/data.tf`:

```hcl
# ctech-cdk's Alpine ARM64 AMI and its published Alpine script library —
# only fetched when this environment actually opts into os_family=alpine, so
# an environment that has never run the Alpine AMI/script pipeline doesn't
# fail terraform plan/apply for an unrelated SSM parameter it will never use.
data "aws_ssm_parameter" "alpine_arm64_ami" {
  count = var.os_family == "alpine" ? 1 : 0
  name  = "/ctech/${var.environment}/ami/alpine/arm64"
}

data "aws_ssm_parameter" "ec2_scripts_alpine_bucket" {
  count = var.os_family == "alpine" ? 1 : 0
  name  = "/ctech/${var.environment}/ec2-scripts-alpine/bucket"
}

data "aws_ssm_parameter" "ec2_scripts_alpine_version" {
  count = var.os_family == "alpine" ? 1 : 0
  name  = "/ctech/${var.environment}/ec2-scripts-alpine/version"
}
```

- [ ] **Step 2: Validate**

Run: `cd terraform/lbalancer && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add terraform/lbalancer/data.tf
git commit -m "feat(lbalancer): add Alpine AMI and script-bucket data sources"
```

### Task 9: `assets/refresh-cloudflare-ips-alpine.sh.tftpl`

**Files:**
- Create: `assets/refresh-cloudflare-ips-alpine.sh.tftpl`

**Interfaces:**
- Consumes: `ctech-ec2-agent ec2-describe-instances`? — no, this script does not need any new subcommand; it only needs `ec2-describe-instances`'s sibling. Actually check: it calls `aws ec2 describe-managed-prefix-lists` + `aws ec2 get-managed-prefix-list-entries`, which the existing `prefix-list` subcommand (already shipped, `prefixlist.go`) already replaces in one call.
- Produces: `/etc/nftables.nft`, `/etc/haproxy/cloudflare-proxies.lst`, `/etc/haproxy/cloudfront-origin-proxies.lst`, `/etc/nftables/ctech-edge.nft` — same paths `refresh-cloudflare-ips.sh.tftpl` writes, consumed by Task 11's `reconcile-alpine.sh.tftpl` reload check and by nftables at boot (Task 10's bootstrap script enables the `nftables` OpenRC service).

This is the smallest of the three ports: only the AWS call and the persistence file for nftables differ from the AL2023 version.

- [ ] **Step 1: Write the file**

Create `assets/refresh-cloudflare-ips-alpine.sh.tftpl` as a copy of `assets/refresh-cloudflare-ips.sh.tftpl` with exactly two changes:

1. Replace lines 125-133 (the `aws ec2 describe-managed-prefix-lists` + `aws ec2 get-managed-prefix-list-entries` pair) with:

```bash
downloaded_cloudfront=$(ctech-ec2-agent prefix-list \
  -name com.amazonaws.global.cloudfront.origin-facing -region us-east-1 2>/dev/null || true)
```

(`ctech-ec2-agent prefix-list` already validates a minimum entry count itself and exits non-zero on a partial list — the `-ge 40` check three lines below in the original script becomes redundant but harmless to leave in place, since a non-empty `$downloaded_cloudfront` from this subcommand is always a complete list.)

2. Replace lines 185-187 (the AL2023 `/etc/sysconfig/nftables.conf` write, RHEL/systemd-specific path) with:

```bash
cat > /etc/nftables.nft <<'CONF'
include "/etc/nftables/ctech-edge.nft"
CONF
```

Everything else — the static fallback IP lists, `valid_ranges`/`install_ranges` functions, the `nft --check`/`nft --file` application, the `proxy_lists_changed` HAProxy reload gate at the bottom — is copied verbatim, including its final `systemctl is-active --quiet haproxy` / `systemctl reload haproxy` pair, which Task 10 changes to `rc-service haproxy status`/`rc-service haproxy reload` (kept identical here so this task stays a one-file, two-edit change; the OpenRC swap belongs to Task 10 since that's where every other systemd-to-OpenRC edit in the bootstrap script lives).

Actually apply that OpenRC swap here too, since this file's own last three lines are the only systemd calls it contains and leaving them in would make this file fail on Alpine on its own re-run (the daily periodic job calls this script standalone, not through bootstrap):

```bash
if [ "$proxy_lists_changed" = true ] && rc-service haproxy status >/dev/null 2>&1; then
  /usr/local/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg
  rc-service haproxy reload
fi
```

- [ ] **Step 2: Syntax-check the script**

Run: `bash -n assets/refresh-cloudflare-ips-alpine.sh.tftpl`

`.tftpl` files use `${...}` for real Terraform interpolation and `$${...}` to escape a literal shell `${...}` — `bash -n` only understands the file after that substitution. Strip the escaping first:

```bash
sed 's/\$\$/\$/g' assets/refresh-cloudflare-ips-alpine.sh.tftpl > /tmp/refresh-cloudflare-ips-alpine-check.sh
bash -n /tmp/refresh-cloudflare-ips-alpine-check.sh
```

Expected: no output (valid syntax)

- [ ] **Step 3: Diff against the AL2023 original to confirm scope**

Run: `diff assets/refresh-cloudflare-ips.sh.tftpl assets/refresh-cloudflare-ips-alpine.sh.tftpl`
Expected: only the three hunks from Step 1 differ — the Cloudflare/CloudFront static fallback lists, the CIDR validation logic, and the nftables ruleset generation itself are byte-identical.

- [ ] **Step 4: Commit**

```bash
git add assets/refresh-cloudflare-ips-alpine.sh.tftpl
git commit -m "feat(lbalancer): add Alpine port of refresh-cloudflare-ips.sh.tftpl"
```

### Task 10: `assets/bootstrap-alpine.sh.tftpl`

**Files:**
- Create: `assets/bootstrap-alpine.sh.tftpl`

**Interfaces:**
- Consumes: `ctech-ec2-agent s3-cp` (existing), `ctech-ec2-agent s3-put`/`ssm-get`/`ssm-put` (existing + Task 5), the same `local.userdata_template_vars` map Task 12 extends with `ec2_scripts_alpine_bucket`/`ec2_scripts_alpine_version`/`haproxy_artifact_sha256_alpine_path`.
- Produces: `/usr/local/sbin/haproxy`, `/etc/init.d/haproxy`, `/etc/init.d/ctech-cloudflare-ips` + `/etc/periodic/daily/ctech-cloudflare-ips`, `/etc/init.d/ctech-lbalancer-reconcile`, `/etc/rsyslog.d/49-haproxy.conf`, `/etc/logrotate.d/ctech-lbalancer` — all consumed by Task 11's reconcile script and by the boot sequence itself.

- [ ] **Step 1: Write the file**

Create `assets/bootstrap-alpine.sh.tftpl`, a full port of `assets/bootstrap.sh.tftpl`:

```bash
#!/bin/bash
set -euo pipefail

export AWS_USE_DUALSTACK_ENDPOINT=true

CTECH_SCRIPTS_ALPINE_BUCKET='${ec2_scripts_alpine_bucket}'
CTECH_SCRIPTS_ALPINE_VERSION='${ec2_scripts_alpine_version}'
ctech_run(){ s="$1"; shift; ctech-ec2-agent s3-cp -bucket "$CTECH_SCRIPTS_ALPINE_BUCKET" -key "$CTECH_SCRIPTS_ALPINE_VERSION/$s" -dest "/tmp/$s" >/dev/null; bash "/tmp/$s" "$@"; }

# setup-base.sh and setup-dualstack.sh are deliberately not used, for the same
# reasons the AL2023 script skips their equivalents: this box has no `webapp`
# user, no /opt/app, no nginx.

# 128 MiB, not 256: this box's 1 GiB root volume needs the extra headroom for
# the HAProxy source build below (verified live — 256 MiB left the build
# short on disk). setup-swap.sh (assets/ec2/) is AL2023-only and not published
# to the ec2-scripts-alpine bucket, so this is inlined rather than ctech_run.
if [ ! -f /var/swapfile ]; then
  dd if=/dev/zero of=/var/swapfile bs=1M count=128
  chmod 600 /var/swapfile
  mkswap /var/swapfile
  swapon /var/swapfile
  grep -q '^/var/swapfile ' /etc/fstab || echo "/var/swapfile swap swap defaults 0 0" >> /etc/fstab
fi

# jq/nftables/rsyslog/logrotate: same runtime role as the AL2023 list. openssl
# is Alpine's CLI+libs package (AL2023's curl-minimal already ships the CLI;
# Alpine's cloud image does not, so it must be requested explicitly here,
# unlike AL2023's libs-only openssl-libs). pcre2/zlib are HAProxy's runtime
# link targets, confirmed working live via `haproxy -vv` after this exact
# build. libxcrypt has no Alpine/musl equivalent and nothing here calls it.
apk add --no-cache jq nftables rsyslog logrotate openssl pcre2 zlib

if [ '${enable_ssm_agent}' = 'true' ]; then
  cat > /etc/amazon/ssm/amazon-ssm-agent.json <<'SSM'
{ "Agent": { "UseDualStackEndpoint": true } }
SSM
  rc-update add amazon-ssm-agent default
  rc-service amazon-ssm-agent restart
else
  # amazon-ssm-agent is baked into every Alpine AMI unconditionally by
  # ctech-cdk's Packer pipeline, unlike AL2023 where it's a conditional dnf
  # install — disabling it here stops the already-installed agent rather than
  # skipping its installation.
  rc-update del amazon-ssm-agent default 2>/dev/null || true
  rc-service amazon-ssm-agent stop 2>/dev/null || true
fi

id -u haproxy >/dev/null 2>&1 || {
  addgroup -S haproxy 2>/dev/null || true
  adduser -S -D -H -G haproxy -s /sbin/nologin haproxy
}
install -d -o haproxy -g haproxy -m 0750 /var/lib/haproxy
install -d -o haproxy -g haproxy -m 0750 /var/log/haproxy
install -d -o root -g haproxy -m 0750 /etc/haproxy/tls

HAPROXY_VERSION='${haproxy_version}'
HAPROXY_BRANCH="$${HAPROXY_VERSION%.*}"
HAPROXY_TARBALL="haproxy-$${HAPROXY_VERSION}.tar.gz"
HAPROXY_ARTIFACT_BUCKET='${haproxy_artifact_bucket}'
HAPROXY_ARTIFACT_SHA256_PATH='${haproxy_artifact_sha256_alpine_path}'
HAPROXY_ARTIFACT=/tmp/haproxy-artifact.tar.gz
artifact_installed=false

artifact_sha256=$(ctech-ec2-agent ssm-get -name "$HAPROXY_ARTIFACT_SHA256_PATH" 2>/dev/null || true)
if [[ "$artifact_sha256" =~ ^[0-9a-f]{64}$ ]] && \
   ctech-ec2-agent s3-cp -bucket "$HAPROXY_ARTIFACT_BUCKET" -key "$artifact_sha256" -dest "$HAPROXY_ARTIFACT" >/dev/null 2>&1 && \
   echo "$artifact_sha256  $HAPROXY_ARTIFACT" | sha256sum --check --strict; then
  artifact_members=$(tar -tzf "$HAPROXY_ARTIFACT")
  if [ "$artifact_members" = 'usr/local/sbin/haproxy' ]; then
    tar -xzf "$HAPROXY_ARTIFACT" -C /
    chmod 0755 /usr/local/sbin/haproxy
    artifact_installed=true
    echo "Installed HAProxy $${HAPROXY_VERSION} artifact $${artifact_sha256}"
  else
    echo "Ignoring HAProxy artifact with unexpected members: $${artifact_members}" >&2
  fi
fi

if [ "$artifact_installed" != true ]; then
  # linux-headers is not part of build-base and the build fails on
  # linux/types.h without it — confirmed live.
  apk add --no-cache build-base openssl-dev pcre2-dev zlib-dev linux-headers
  curl --fail --silent --show-error --location \
    "https://www.haproxy.org/download/$${HAPROXY_BRANCH}/src/$${HAPROXY_TARBALL}" \
    --output "/tmp/$${HAPROXY_TARBALL}"
  echo "${haproxy_source_sha256}  /tmp/$${HAPROXY_TARBALL}" | sha256sum --check --strict
  tar -xzf "/tmp/$${HAPROXY_TARBALL}" -C /tmp
  make -C "/tmp/haproxy-$${HAPROXY_VERSION}" -j1 \
    TARGET=linux-musl USE_OPENSSL=1 USE_PCRE2=1 USE_ZLIB=1 USE_PROMEX=1
  make -C "/tmp/haproxy-$${HAPROXY_VERSION}" install-bin PREFIX=/usr/local
  strip /usr/local/sbin/haproxy

  artifact_root=$(mktemp -d)
  install -D -m 0755 /usr/local/sbin/haproxy \
    "$artifact_root/usr/local/sbin/haproxy"
  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$artifact_root" -cf - usr/local/sbin/haproxy | gzip -n -9 > "$HAPROXY_ARTIFACT"
  artifact_sha256=$(sha256sum "$HAPROXY_ARTIFACT" | awk '{print $1}')

  if ctech-ec2-agent s3-put -bucket "$HAPROXY_ARTIFACT_BUCKET" -key "$artifact_sha256" -file "$HAPROXY_ARTIFACT"; then
    ctech-ec2-agent ssm-put -name "$HAPROXY_ARTIFACT_SHA256_PATH" -value "$artifact_sha256" || \
      echo "HAProxy artifact uploaded but its SSM pointer could not be updated" >&2
  else
    echo "HAProxy artifact cache upload failed; continuing with the local binary" >&2
  fi

  rm -rf "/tmp/$${HAPROXY_TARBALL}" "/tmp/haproxy-$${HAPROXY_VERSION}" "$artifact_root"
  apk del build-base openssl-dev pcre2-dev zlib-dev linux-headers
fi

/usr/local/sbin/haproxy -vv

cat > /etc/init.d/haproxy <<'INITD'
#!/sbin/openrc-run
description="HAProxy LTS edge proxy"
command="/usr/local/sbin/haproxy"
command_args="-Ws -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid"
env HAPROXY_MWORKER=1
pidfile="/run/haproxy.pid"
supervisor="supervise-daemon"
respawn_delay=2
respawn_max=0

depend() {
	need net
}

start_pre() {
	checkpath -f /etc/haproxy/haproxy.cfg || { eerror "haproxy.cfg missing"; return 1; }
}

reload() {
	ebegin "Reloading haproxy"
	/usr/local/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg && kill -USR2 "$(cat /run/haproxy.pid)"
	eend $?
}
INITD
chmod 0755 /etc/init.d/haproxy

mkdir -p /etc/rsyslog.d
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

cat > /etc/init.d/ctech-cloudflare-ips <<'INITD'
#!/sbin/openrc-run
description="Refresh trusted CDN ranges and Cloudflare-only IPv6 firewall"
command="/opt/ctech-lbalancer/refresh-cloudflare-ips.sh"
command_background="no"
depend() {
	need net
}
INITD
chmod 0755 /etc/init.d/ctech-cloudflare-ips

mkdir -p /etc/periodic/daily
cat > /etc/periodic/daily/ctech-cloudflare-ips <<'PERIODIC'
#!/bin/bash
# OpenRC has no RandomizedDelaySec — jitter the run itself.
sleep $((RANDOM % 1800))
/opt/ctech-lbalancer/refresh-cloudflare-ips.sh
PERIODIC
chmod 0755 /etc/periodic/daily/ctech-cloudflare-ips

cat > /etc/init.d/ctech-lbalancer-reconcile <<'INITD'
#!/sbin/openrc-run
description="Reconcile HAProxy routes and ASG targets every 30 seconds"
command="/opt/ctech-lbalancer/reconcile-loop.sh"
command_background="yes"
pidfile="/run/ctech-lbalancer-reconcile.pid"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
output_log="/var/log/ctech-lbalancer-reconcile.log"
error_log="/var/log/ctech-lbalancer-reconcile.log"

depend() {
	need net
	after ctech-cloudflare-ips rsyslog
}
INITD
chmod 0755 /etc/init.d/ctech-lbalancer-reconcile

# busybox crond's finest granularity is one minute — the AL2023 systemd timer
# runs every 30s with AccuracySec=5s, which cron cannot express. This
# supervised loop is the one behavioral-shape change in this migration:
# a periodic oneshot timer becomes a persistent process, restarted by
# supervise-daemon if it ever exits.
cat > /opt/ctech-lbalancer/reconcile-loop.sh <<'LOOP'
#!/bin/bash
export AWS_USE_DUALSTACK_ENDPOINT=true
while true; do
  /opt/ctech-lbalancer/reconcile.sh || true
  sleep 30
done
LOOP
chmod 0750 /opt/ctech-lbalancer/reconcile-loop.sh

rc-update add nftables default
rc-update add rsyslog default
rc-service rsyslog restart
/opt/ctech-lbalancer/refresh-cloudflare-ips.sh
rc-update add ctech-cloudflare-ips default
rc-service ctech-cloudflare-ips start
rc-update add ctech-lbalancer-reconcile default
rc-service ctech-lbalancer-reconcile start
/opt/ctech-lbalancer/reconcile.sh || true
```

- [ ] **Step 2: Syntax-check the script**

Run:
```bash
sed 's/\$\$/\$/g' assets/bootstrap-alpine.sh.tftpl > /tmp/bootstrap-alpine-check.sh
bash -n /tmp/bootstrap-alpine-check.sh
```
Expected: no output. Also `bash -n` each heredoc's embedded script individually where one exists (`/opt/ctech-lbalancer/reconcile-loop.sh`'s body) — extract it and check separately since heredocs aren't parsed by the outer `bash -n`:

```bash
sed -n '/^cat > \/opt\/ctech-lbalancer\/reconcile-loop.sh/,/^LOOP$/p' assets/bootstrap-alpine.sh.tftpl | sed '1d;$d' > /tmp/reconcile-loop-check.sh
bash -n /tmp/reconcile-loop-check.sh
```
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add assets/bootstrap-alpine.sh.tftpl
git commit -m "feat(lbalancer): add Alpine port of bootstrap.sh.tftpl"
```

### Task 11: `assets/reconcile-alpine.sh.tftpl`

**Files:**
- Create: `assets/reconcile-alpine.sh.tftpl`

**Interfaces:**
- Consumes: `ctech-ec2-agent ssm-get-by-path` (Task 1), `asg-describe` (Task 2), `ec2-describe-instances` (Task 3), `asg-set-unhealthy` (Task 4), plus the already-shipped `ssm-get`, `ssm-put`, `route53-upsert`.
- Produces: `/etc/haproxy/haproxy.cfg` — same file `bootstrap-alpine.sh.tftpl`'s `haproxy` OpenRC service reads.

This is the largest, most-frequently-run script (every 30s under Task 10's supervised loop). Every line of certificate handling, HAProxy config generation, and CORS/ACL logic in `reconcile.sh.tftpl` is data manipulation (`openssl`, `jq`, string building) with zero AWS-CLI or systemd calls — none of that changes. Only the six lines below differ.

- [ ] **Step 1: Write the file**

Create `assets/reconcile-alpine.sh.tftpl` as a copy of `assets/reconcile.sh.tftpl` with exactly these five substitutions (line numbers refer to the original file):

1. `parameter()` (lines 14-17) — same shape, different command:

```bash
parameter() {
  ctech-ec2-agent ssm-get -name "$1" -decrypt 2>/dev/null
}
```

2. Line 94-95, the routes fetch:

```bash
routes=$(ctech-ec2-agent ssm-get-by-path -path '${routes_path}' \
  | jq -ce '[.Parameters[].Value | fromjson]')
```

3. Lines 130-134, the ASG describe (comma-join replaces the AWS CLI's space-separated array args):

```bash
if [ "$${#asg_names[@]}" -gt 0 ]; then
  groups=$(ctech-ec2-agent asg-describe -names "$(IFS=,; echo "$${asg_names[*]}")")
else
  groups='{"AutoScalingGroups":[]}'
fi
```

4. Lines 141-145, the instance describe (same comma-join pattern):

```bash
if [ "$${#instance_ids[@]}" -gt 0 ]; then
  instances=$(ctech-ec2-agent ec2-describe-instances -ids "$(IFS=,; echo "$${instance_ids[*]}")")
else
  instances='{"Reservations":[]}'
fi
```

5. Lines 322-326, the HAProxy service check/reload (OpenRC instead of systemd):

```bash
if rc-service haproxy status >/dev/null 2>&1; then
  rc-service haproxy reload
else
  rc-update add haproxy default
  rc-service haproxy start
fi
```

6. Line 359-360, auto-heal (drop the two AWS-CLI flags — `asg-set-unhealthy` always applies both):

```bash
      ctech-ec2-agent asg-set-unhealthy -instance-id "$instance_id"
```

7. Line 387-388, the private DNS UPSERT — replace the raw `aws route53 change-resource-record-sets --change-batch "$change_batch"` call (and delete the `change_batch=$(jq -cn ...)` line immediately above it, no longer needed) with the existing subcommand:

```bash
      if ctech-ec2-agent route53-upsert -zone-id "$private_zone_id" \
          -name '${internal_lbalancer_domain}' -value "$private_ipv4" -ttl 10; then
        printf '%s\n' "$private_ipv4" > "$private_dns_state"
      else
        echo 'Private load-balancer DNS update failed; HAProxy remains active' >&2
      fi
```

8. Lines 402-403, the origin IPv6 publish:

```bash
    ctech-ec2-agent ssm-put -name '${origin_ipv6_path}' -value "$ipv6"
```

Everything else — TLS install/validation, the `routes` jq schema validation, the `resolved` targets join, the entire HAProxy config heredoc/generation loop (lines 163-327 excluding the one reload swap above), and the Cloudflare AAAA update block at the bottom (pure `curl` to the Cloudflare API, no AWS/systemd calls) — is copied verbatim.

- [ ] **Step 2: Syntax-check the script**

```bash
sed 's/\$\$/\$/g' assets/reconcile-alpine.sh.tftpl > /tmp/reconcile-alpine-check.sh
bash -n /tmp/reconcile-alpine-check.sh
```
Expected: no output

- [ ] **Step 3: Diff against the AL2023 original to confirm scope**

Run: `diff assets/reconcile.sh.tftpl assets/reconcile-alpine.sh.tftpl`
Expected: only the 8 hunks from Step 1 differ (roughly 25-30 changed lines out of 435) — the certificate handling, schema validation, HAProxy config generation, and Cloudflare update logic are byte-identical.

- [ ] **Step 4: Commit**

```bash
git add assets/reconcile-alpine.sh.tftpl
git commit -m "feat(lbalancer): add Alpine port of reconcile.sh.tftpl"
```

### Task 12: wire `os_family` into `compute.tf` and `locals.tf`

**Files:**
- Modify: `terraform/lbalancer/locals.tf`
- Modify: `terraform/lbalancer/compute.tf`

**Interfaces:**
- Consumes: `var.os_family` (Task 7), the three data sources from Task 8, `assets/bootstrap-alpine.sh.tftpl`/`reconcile-alpine.sh.tftpl`/`refresh-cloudflare-ips-alpine.sh.tftpl` (Tasks 9-11).
- Produces: `aws_launch_template.this` now launches the Alpine AMI with a 1 GiB volume when `var.os_family == "alpine"`; unchanged otherwise. Consumed by Task 13's IAM statement (needs the new SSM path this task references) and Task 14's live boot test.

- [ ] **Step 1: Add the Alpine HAProxy artifact-cache SSM path**

In `terraform/lbalancer/locals.tf`, add a sibling key to the existing `ssm_paths.haproxy_artifact_sha256` (which is pinned to the AL2023/glibc binary and must stay untouched — a musl binary is not interchangeable with it):

```hcl
    haproxy_artifact_sha256         = "/ctech/${var.environment}/lbalancer/haproxy/${local.haproxy_version}/al2023-arm64/artifact-sha256"
    haproxy_artifact_sha256_alpine  = "/ctech/${var.environment}/lbalancer/haproxy/${local.haproxy_version}/alpine-arm64/artifact-sha256"
```

- [ ] **Step 2: Extend `local.userdata_template_vars` and select the AL2023-vs-Alpine templates**

In `terraform/lbalancer/compute.tf`, inside the `locals` block:

```hcl
  userdata_template_vars = {
    aws_region                       = var.aws_region
    environment                      = var.environment
    haproxy_version                  = local.haproxy_version
    haproxy_source_sha256            = local.haproxy_source_sha256
    routes_path                      = local.ssm_paths.routes
    origin_ipv6_path                 = local.ssm_paths.origin_ipv6
    tls_certificate_path             = local.ssm_paths.tls_certificate
    tls_private_key_path             = local.ssm_paths.tls_private_key
    internal_tls_certificate_path    = local.ssm_paths.internal_tls_certificate
    internal_tls_private_key_path    = local.ssm_paths.internal_tls_private_key
    aop_ca_path                      = local.ssm_paths.aop_ca
    cloudflare_token_path            = local.ssm_paths.cloudflare_dns_token
    cloudflare_zone_id               = var.cloudflare_zone_id
    origin_domain                    = local.origin_domain
    enable_internal_m2m              = tostring(var.enable_internal_m2m)
    vpc_ipv4_cidr                    = data.aws_vpc.this.cidr_block
    private_zone_id_path             = local.private_hosted_zone_id_parameter
    private_zone_name                = local.private_zone_name
    internal_lbalancer_domain        = local.internal_lbalancer_domain
    enable_ssm_agent                 = tostring(var.enable_ssm_agent)
    haproxy_artifact_bucket          = data.aws_s3_bucket.artifacts.bucket
    haproxy_artifact_sha256_path     = local.ssm_paths.haproxy_artifact_sha256
    haproxy_artifact_sha256_alpine_path = local.ssm_paths.haproxy_artifact_sha256_alpine
    ec2_scripts_bucket               = data.aws_ssm_parameter.ec2_scripts_bucket.value
    ec2_scripts_version              = data.aws_ssm_parameter.ec2_scripts_version.value
    ec2_scripts_alpine_bucket        = var.os_family == "alpine" ? data.aws_ssm_parameter.ec2_scripts_alpine_bucket[0].value : ""
    ec2_scripts_alpine_version       = var.os_family == "alpine" ? data.aws_ssm_parameter.ec2_scripts_alpine_version[0].value : ""
  }

  reconcile_sh = var.os_family == "alpine" ? templatefile("${path.module}/../../assets/reconcile-alpine.sh.tftpl", local.userdata_template_vars) : templatefile("${path.module}/../../assets/reconcile.sh.tftpl", local.userdata_template_vars)

  refresh_cloudflare_ips_sh = var.os_family == "alpine" ? templatefile("${path.module}/../../assets/refresh-cloudflare-ips-alpine.sh.tftpl", local.userdata_template_vars) : templatefile("${path.module}/../../assets/refresh-cloudflare-ips.sh.tftpl", local.userdata_template_vars)

  bootstrap_sh = var.os_family == "alpine" ? templatefile("${path.module}/../../assets/bootstrap-alpine.sh.tftpl", local.userdata_template_vars) : templatefile("${path.module}/../../assets/bootstrap.sh.tftpl", local.userdata_template_vars)
```

`local.user_data` itself (the `base64encode(<<-EOF ... EOF)` block right below, which gzips and writes out `reconcile_sh`/`refresh_cloudflare_ips_sh`/`bootstrap_sh` and execs `bootstrap.sh`) needs **no change** — it already only references these three locals by name, and Alpine's baked-in `ctech-userdata` OpenRC service (already shipped in ctech-cdk's Packer pipeline) fetches and runs this same raw `#!/bin/bash` payload directly via IMDS, the same way `ValkeyStackV2`'s user-data already does on that AMI. No cloud-init-specific handling is needed here.

- [ ] **Step 3: Branch `image_id` and `volume_size` on `aws_launch_template.this`**

In `terraform/lbalancer/compute.tf`, inside `resource "aws_launch_template" "this"`:

```hcl
  image_id = var.os_family == "alpine" ? data.aws_ssm_parameter.alpine_arm64_ami[0].value : data.aws_ssm_parameter.al2023_arm64_ami.value
```

```hcl
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.os_family == "alpine" ? 1 : 4
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }
```

- [ ] **Step 4: Validate and plan-dry-run against both values**

Run: `cd terraform/lbalancer && terraform validate`
Expected: `Success! The configuration is valid.`

Since this repo's backend needs real AWS credentials the agent doesn't have, hand the user this pair of commands to confirm the plan is sane for both branches (read-only, no `-auto-approve`, never applied by the agent):

```bash
terraform plan -var os_family=al2023   # must show no changes to image_id/volume_size
terraform plan -var os_family=alpine   # must show the new AMI + 1 GiB volume, and nothing else
```

- [ ] **Step 5: Commit**

```bash
git add terraform/lbalancer/locals.tf terraform/lbalancer/compute.tf
git commit -m "feat(lbalancer): branch image_id, templatefile sources, and volume_size on os_family"
```

### Task 13: `iam.tf` — add the Alpine HAProxy artifact-cache SSM path

**Files:**
- Modify: `terraform/lbalancer/iam.tf`

**Interfaces:**
- Consumes: `local.ssm_paths.haproxy_artifact_sha256_alpine` (Task 12, Step 1).

The spec states no IAM changes are needed because the five new `ctech-ec2-agent` *actions* (`ssm:GetParametersByPath`, `autoscaling:DescribeAutoScalingGroups`, `autoscaling:SetInstanceHealth`, `ec2:DescribeInstances`, `s3:PutObject`) are already granted. That part is correct and confirmed by reading the existing `GetLbalancerSecrets`/`ReconcileDiscovery`/`AutoHeal`/`HaproxyArtifactCache` statements. What the spec missed: `GetLbalancerSecrets` and `PublishOriginState` name the AL2023 `haproxy_artifact_sha256` parameter's **exact ARN**, not a wildcard — the new Alpine-specific SSM parameter path from Task 12 is a different resource string and needs its own ARN added to both statements, or `ctech-ec2-agent ssm-get`/`ssm-put` will get `AccessDenied` on it the first time `bootstrap-alpine.sh.tftpl` runs.

- [ ] **Step 1: Add the new resource to both statements**

In `terraform/lbalancer/iam.tf`, `data "aws_iam_policy_document" "instance"`:

In the `GetLbalancerSecrets` statement's `resources`, add a line next to the existing `haproxy_artifact_sha256` entry:

```hcl
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.haproxy_artifact_sha256}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.haproxy_artifact_sha256_alpine}",
```

In the `PublishOriginState` statement's `resources`:

```hcl
  statement {
    sid     = "PublishOriginState"
    actions = ["ssm:PutParameter"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.origin_ipv6}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.haproxy_artifact_sha256}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.haproxy_artifact_sha256_alpine}",
    ]
  }
```

- [ ] **Step 2: Validate**

Run: `cd terraform/lbalancer && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Confirm the five subcommand actions really are already covered (read-only check, no edit expected)**

Re-read `terraform/lbalancer/iam.tf` and confirm, in writing in the commit message or a PR comment: `ssm:GetParametersByPath` is in `GetLbalancerSecrets`, `autoscaling:DescribeAutoScalingGroups` and `ec2:DescribeInstances` are in `ReconcileDiscovery`, `autoscaling:SetInstanceHealth` is in `AutoHeal`, and `s3:PutObject` is in `HaproxyArtifactCache` (bucket-wildcarded, so it already covers whatever key the Alpine binary happens to be cached under). If any of these five is missing, that is a plan gap — stop and add the missing statement before proceeding to Task 14.

- [ ] **Step 4: Commit**

```bash
git add terraform/lbalancer/iam.tf
git commit -m "fix(lbalancer): grant access to the Alpine HAProxy artifact-cache SSM path"
```

### Task 14: live verification — the two untested Alpine patterns, then a full boot

**Files:** none (verification only; if either check below fails, open a follow-up task against the specific file it implicates before continuing)

**Interfaces:** none new.

This task cannot start until: Part 1 is merged and `ctech-cdk`'s CI has built a `ctech-ec2-agent` binary containing all five new subcommands, a fresh Alpine AMI has been built with `.github/workflows/build-alpine-ami.yml` (picking up that binary), and the `ec2-scripts-alpine` bucket contains this plan's three new `-alpine.sh.tftpl` scripts (published by `ctech-cdk`'s `Ec2ScriptsStack` — no ctech-lbalancer-side action needed for that publish, it's driven by ctech-cdk's own CI on every push to `assets/ec2-alpine/`... **note:** these three new scripts currently live in `ctech-lbalancer`'s own `assets/` directory, not `ctech-cdk`'s `assets/ec2-alpine/` — they are fetched via `ctech_run` from the `ec2-scripts-alpine` bucket only for scripts genuinely shared across services; `bootstrap-alpine.sh.tftpl`/`reconcile-alpine.sh.tftpl`/`refresh-cloudflare-ips-alpine.sh.tftpl` are lbalancer-specific and are rendered locally by `templatefile()` and pushed as inline user-data, exactly like their AL2023 counterparts already are — re-read Task 10/11's `ctech_run` usage: it only fetches `ec2-scripts-alpine`-published *shared* Alpine scripts if this repo ever needs one (it currently doesn't; the three new templates call no such shared script). This note is here so the executor doesn't block Task 14 on a ctech-cdk publish step that Part 2 doesn't actually depend on beyond the `ctech-ec2-agent` binary and AMI itself).

- [ ] **Step 1: Ask the user to launch a disposable Alpine ARM64 test instance**

Hand the user this (adjust the AMI SSM parameter to their environment):

```bash
AMI=$(aws ssm get-parameter --name /ctech/dev/ami/alpine/arm64 --query Parameter.Value --output text --profile ctech)
aws ec2 run-instances --image-id "$AMI" --instance-type t4g.small \
  --count 1 --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=lbalancer-alpine-test}]' \
  --profile ctech
```

(`t4g.small`, not `t4g.nano`: this is a throwaway verification box, not the production sizing — extra headroom keeps the two checks below from being blocked by unrelated memory pressure.)

- [ ] **Step 2: Verify `logrotate` on Alpine, live, via SSM Session Manager**

```bash
doas apk add --no-cache logrotate
doas mkdir -p /etc/logrotate.d
cat <<'EOF' | doas tee /etc/logrotate.d/test-lbalancer >/dev/null
/var/log/haproxy/access.log {
  daily
  rotate 3
  size 20M
  missingok
  notifempty
  compress
  copytruncate
}
EOF
doas mkdir -p /var/log/haproxy
doas sh -c 'head -c 25M /dev/urandom | base64 > /var/log/haproxy/access.log'
doas logrotate --force /etc/logrotate.d/test-lbalancer
ls -la /var/log/haproxy/
```
Expected: `access.log` is truncated (copytruncate) and a `access.log-<date>.gz` (or `.1.gz`) rotated file exists. If `logrotate --force` errors or no rotated file appears, this is a real blocker for Task 10's design — report it back before proceeding.

- [ ] **Step 3: Verify the supervised `while ... sleep 30` reconcile-loop pattern under `supervise-daemon`**

```bash
doas tee /opt/test-loop.sh >/dev/null <<'EOF'
#!/bin/bash
while true; do
  echo "tick $(date +%s)" >> /tmp/test-loop.log
  sleep 30
done
EOF
doas chmod 0750 /opt/test-loop.sh
doas tee /etc/init.d/test-loop >/dev/null <<'EOF'
#!/sbin/openrc-run
description="test loop"
command="/opt/test-loop.sh"
command_background="yes"
pidfile="/run/test-loop.pid"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
EOF
doas chmod 0755 /etc/init.d/test-loop
doas rc-service test-loop start
sleep 65
cat /tmp/test-loop.log   # expect at least 2 "tick" lines, 30s apart
doas rc-service test-loop status   # expect "started"
pid=$(doas cat /run/test-loop.pid)
doas kill -9 "$pid"
sleep 8
doas rc-service test-loop status   # expect "started" again — supervise-daemon respawned it
```
Expected: ticks land roughly 30s apart, and the service auto-restarts after being killed. If `supervise-daemon` does not respawn it, this invalidates Task 10's `ctech-lbalancer-reconcile` design — report before proceeding (the fallback would be a `/etc/periodic`-driven watchdog that restarts the loop, a more complex design change).

- [ ] **Step 4: Run the real `bootstrap-alpine.sh.tftpl` on the test instance**

Render it locally with the same variables `terraform plan -var os_family=alpine` would produce (or, simpler, have the user actually run `terraform apply -var os_family=alpine` against a `dev` environment's real `ctech-lbalancer` stack once Steps 1-3 pass) and confirm:

```bash
doas cat /var/log/ctech-userdata.log   # bootstrap-alpine.sh's own output, via the ctech-userdata OpenRC service
doas rc-service haproxy status
doas rc-service ctech-lbalancer-reconcile status
doas cat /etc/haproxy/haproxy.cfg   # non-empty, has at least one backend
doas nft list ruleset               # ctech_edge table present
```
Expected: all green — `haproxy` and `ctech-lbalancer-reconcile` both `started`, a real `haproxy.cfg` generated from live route data, nftables table present. Any failure here is a genuine, previously-unverified integration gap between Tasks 9-11 (each verified individually via `bash -n`/diff, never end-to-end) — fix the specific script and re-run this step before considering the migration done.

- [ ] **Step 5: Terminate the disposable test instance**

```bash
aws ec2 terminate-instances --instance-ids <the id from Step 1> --profile ctech
```

- [ ] **Step 6: Note the disk-margin risk for future HAProxy version bumps**

No code change — just a durable note for whoever bumps `local.haproxy_version` next: re-run Step 4 (or at minimum, re-run the HAProxy build portion of `bootstrap-alpine.sh.tftpl` by hand on a test box) before merging that bump, since the 1 GiB/128 MiB margin was measured at ~30-110 MiB free at peak for HAProxy 3.4.3 specifically.

---

## Self-Review

**Spec coverage:**
- Rollout topology (direct AMI swap, `os_family` gate, no canary) — Tasks 7, 12.
- HAProxy `TARGET=linux-musl` source build with the apk dev-package swap and `linux-headers` gotcha — Task 10.
- Rejected apk-`haproxy`-package alternative — not re-litigated in the plan; it's a spec-level decision record, nothing to implement.
- Five `ctech-ec2-agent` subcommands — Tasks 1-5.
- systemd→OpenRC for all four units (`haproxy`, `ctech-cloudflare-ips`, `ctech-lbalancer-reconcile`, `rsyslog`) plus `logrotate` — Task 10 (services), Task 9 (rsyslog's own `mkdir -p /etc/rsyslog.d` gap — actually in Task 10, since that's where the AL2023 script's `/etc/rsyslog.d/49-haproxy.conf` write lives; corrected: verified this landed in Task 10's Step 1 file content, not Task 9).
- nftables persistence path — Task 9.
- Disk budget (1 GiB / 128 MiB swap) — Tasks 10, 12.
- New-files-only file structure — Tasks 8-13 as a set; confirmed no existing `.tftpl`/`.tf` file's AL2023 behavior changes, only additive `os_family`-gated branches.
- `logrotate` and supervised-loop live-verification gaps the spec explicitly flagged as untested — Task 14, Steps 2-3.
- IAM — Task 13 catches a real gap the spec missed (see Task 13's own explanation): the two new SSM-path ARNs, not the five actions (which genuinely needed no change).

**Placeholder scan:** no TBD/TODO; every code block is complete, copy-pasteable file content or a precise instruction for which existing lines to replace (Tasks 9 and 11 name exact original line numbers rather than repeating all 218/435 lines, per the "no placeholders" rule's allowance for showing *how* — the diff commands in Step 3 of both tasks are the mechanical check that nothing beyond the named hunks changed).

**Type/interface consistency:** `ssmParametersByPathOutput`/`describeASGOutput`/`describeInstancesOutput` field names (Tasks 1-3) match the `jq` filters written into `reconcile-alpine.sh.tftpl` (Task 11) exactly (`.Parameters[].Value`, `.AutoScalingGroups[].Instances[]`, `.Reservations[].Instances[]`, `.State.Name`) — checked field-by-field against the original `reconcile.sh.tftpl`'s filters. `newASGClient` (Task 2) is reused unchanged by `runASGSetUnhealthy` (Task 4) rather than redefined. `ec2_scripts_alpine_bucket`/`ec2_scripts_alpine_version`/`haproxy_artifact_sha256_alpine_path` template variable names are identical between Task 10's `.tftpl` references and Task 12's `userdata_template_vars` map keys.

## Execution Handoff

Plan complete and saved to `docs/plans/2026-08-23-alpine-lbalancer-migration.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
