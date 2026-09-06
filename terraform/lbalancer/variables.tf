# Port of bin/ctech-lbalancer.ts env-var reading + validation.

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage, or prod."
  }
}

variable "vpc_id" {
  type        = string
  description = "Read from /ctech/{env}/network/vpc-id (ctech-cdk NetworkStack output)."
}

variable "instance_type" {
  type    = string
  default = "t4g.nano"
  validation {
    condition     = contains(["t4g.nano", "t4g.micro"], var.instance_type)
    error_message = "instance_type must be t4g.nano or t4g.micro."
  }
}

variable "cloudflare_zone_id" {
  type    = string
  default = "bdfaf9265eacff459d2a6c45e4f99664"
  validation {
    condition     = can(regex("^[a-f0-9]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be a 32-character hexadecimal Zone ID."
  }
}

variable "enable_ssm_agent" {
  type    = bool
  default = true
}

variable "enable_cloudwatch_logs" {
  type        = bool
  default     = true
  description = "Stream HAProxy access and reconciler logs to CloudWatch Logs."
}

variable "enable_internal_m2m" {
  type    = bool
  default = true
}

variable "aws_account" {
  type    = string
  default = "868899309401"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# Blue-green cutover knobs — temporary, not a permanent feature. While the
# CDK stack still owns the
# canonical physical names, set resource_suffix so this root's resources
# (role, instance profile, SG, log group, launch template, ASG) get distinct
# names and can be applied side-by-side without colliding. manage_routes
# gates the SSM route parameters + internal CNAMEs, which the live CDK stack
# still owns until cutover — leave false until CDK's copies are destroyed.
variable "resource_suffix" {
  type    = string
  default = ""
}

variable "manage_routes" {
  type    = bool
  default = true
}

variable "spot_drain_timeout_seconds" {
  type        = number
  default     = 100
  description = "hard-stop-after bound on HAProxy's graceful spot-interruption drain. AWS gives roughly 2 minutes of warning before reclaiming a spot instance; this stays comfortably under that so a hard stop still happens before the instance is reclaimed."
  validation {
    condition     = var.spot_drain_timeout_seconds > 0 && var.spot_drain_timeout_seconds <= 110
    error_message = "spot_drain_timeout_seconds must be a positive number of seconds, at most 110 (the ~2 minute spot warning minus a safety margin)."
  }
}

variable "os_family" {
  type    = string
  default = "alpine"
  validation {
    condition     = contains(["al2023", "alpine"], var.os_family)
    error_message = "os_family must be al2023 or alpine."
  }
}
