variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_account" {
  type    = string
  default = "868899309401"
}

variable "github_repo" {
  type        = string
  default     = "artur-oliveira/ctech-lbalancer"
  description = "GitHub owner/name allowed to publish HAProxy artifacts."
}

variable "publish_branches" {
  type        = list(string)
  default     = ["main"]
  description = "Branches whose push or workflow_dispatch runs may assume the artifact role."

  validation {
    condition     = length(var.publish_branches) > 0 && alltrue([for branch in var.publish_branches : can(regex("^[A-Za-z0-9._/-]+$", branch))])
    error_message = "publish_branches must contain at least one valid Git branch name."
  }
}

# main -> prod, staging -> stage, dev -> dev, matching terraform/lbalancer's
# environment validation. Pull requests are deliberately absent — the PR job
# needs no credentials at all.
variable "deploy_branches" {
  type        = list(string)
  default     = ["main", "staging", "dev"]
  description = "Branches whose push runs may assume the infra role."

  validation {
    condition     = length(var.deploy_branches) > 0 && alltrue([for branch in var.deploy_branches : can(regex("^[A-Za-z0-9._/-]+$", branch))])
    error_message = "deploy_branches must contain at least one valid Git branch name."
  }
}
