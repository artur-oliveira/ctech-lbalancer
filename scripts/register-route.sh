#!/bin/bash
set -euo pipefail

if [ "$#" -lt 7 ] || [ "$#" -gt 9 ]; then
  echo "Usage: $0 ENV NAME HOSTNAME INTERNAL_HOSTNAME|- ASG PORT HEALTH_PATH [HEALTHY_STATUSES] [AUTO_HEAL]" >&2
  echo "Example: $0 prod billing billing-api.aoctech.app billing.internal.aoctech.app prod-ctech-billing-api 8080 /v1.0/health-check 200,207 true" >&2
  exit 2
fi

environment=$1
name=$2
hostname=$3
internal_hostname=$4
asg=$5
port=$6
health_path=$7
healthy_csv=${8:-200}
auto_heal=${9:-true}

[[ "$environment" =~ ^(dev|stage|prod)$ ]] || { echo 'Invalid environment' >&2; exit 2; }
[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo 'Invalid route name' >&2; exit 2; }
[[ "$hostname" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || { echo 'Invalid hostname' >&2; exit 2; }
if [ "$internal_hostname" != '-' ]; then
  [[ "$internal_hostname" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.internal\.aoctech\.app$ ]] || {
    echo 'INTERNAL_HOSTNAME must be inside internal.aoctech.app, or - to disable it' >&2
    exit 2
  }
fi
[[ "$asg" =~ ^[A-Za-z0-9+=,.@_-]+$ ]] || { echo 'Invalid ASG name' >&2; exit 2; }
[[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo 'Invalid port' >&2; exit 2; }
[[ "$health_path" =~ ^/[-A-Za-z0-9._~/?=%\&]*$ ]] || { echo 'Invalid health path' >&2; exit 2; }
[[ "$auto_heal" =~ ^(true|false)$ ]] || { echo 'AUTO_HEAL must be true or false' >&2; exit 2; }

statuses=$(jq -cn --arg csv "$healthy_csv" '
  $csv | split(",") | map(tonumber) |
  if all(.[]; . >= 100 and . <= 599) and length > 0 then . else error("invalid status") end
')
value=$(jq -cn \
  --arg hostname "$hostname" \
  --arg internalHostname "$internal_hostname" \
  --arg asg "$asg" \
  --argjson port "$port" \
  --arg healthPath "$health_path" \
  --argjson healthyStatuses "$statuses" \
  --argjson autoHeal "$auto_heal" \
  '{hostname:$hostname,asg:$asg,port:$port,healthPath:$healthPath,healthyStatuses:$healthyStatuses,autoHeal:$autoHeal}
   + if $internalHostname == "-" then {} else {internalHostname:$internalHostname} end')

aws ssm put-parameter \
  --region "${AWS_REGION:-us-east-1}" \
  --name "/ctech/${environment}/lbalancer/routes/${name}" \
  --type String \
  --tier Standard \
  --value "$value" \
  --overwrite

if [ "$internal_hostname" != '-' ]; then
  zone_id=$(aws ssm get-parameter \
    --region "${AWS_REGION:-us-east-1}" \
    --name /ctech/global/dns/private-hosted-zone-id \
    --query Parameter.Value --output text)
  change_batch=$(jq -cn --arg name "$internal_hostname" '{Changes:[{
    Action:"UPSERT",ResourceRecordSet:{Name:$name,Type:"CNAME",TTL:30,
    ResourceRecords:[{Value:"lbalancer.internal.aoctech.app"}]}
  }]}')
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$zone_id" --change-batch "$change_batch" >/dev/null
fi

echo "Registered ${hostname}; HAProxy and private DNS will converge within about 30 seconds."
