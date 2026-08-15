#!/bin/bash
set -euo pipefail

# One-time setup: creates the shared Terraform state backend (S3 bucket +
# DynamoDB lock table) used by every root module under terraform/. Safe to
# re-run — every step is idempotent.

REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-ctech}"
BUCKET="prod-ctech-terraform-state"
TABLE="ctech_terraform_locks"

if aws s3api head-bucket --bucket "$BUCKET" --profile "$PROFILE" 2>/dev/null; then
  echo "Bucket $BUCKET already exists"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --profile "$PROFILE" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --profile "$PROFILE" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws s3api put-bucket-versioning --bucket "$BUCKET" --profile "$PROFILE" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" --profile "$PROFILE" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$BUCKET" --profile "$PROFILE" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "Created bucket $BUCKET"
fi

if aws dynamodb describe-table --table-name "$TABLE" --profile "$PROFILE" --region "$REGION" >/dev/null 2>&1; then
  echo "Table $TABLE already exists"
else
  aws dynamodb create-table --table-name "$TABLE" --profile "$PROFILE" --region "$REGION" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
  aws dynamodb wait table-exists --table-name "$TABLE" --profile "$PROFILE" --region "$REGION"
  echo "Created table $TABLE"
fi
