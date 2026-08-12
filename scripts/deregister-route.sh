#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 ENV NAME" >&2
  exit 2
fi
[[ "$1" =~ ^(dev|stage|prod)$ ]] || { echo 'Invalid environment' >&2; exit 2; }
[[ "$2" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo 'Invalid route name' >&2; exit 2; }

aws ssm delete-parameter \
  --region "${AWS_REGION:-us-east-1}" \
  --name "/ctech/$1/lbalancer/routes/$2"
echo "Deregistered $2; HAProxy will remove it within about 30 seconds."
