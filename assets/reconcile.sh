#!/bin/bash
set -euo pipefail

export AWS_DEFAULT_REGION=__AWS_REGION__
export AWS_USE_DUALSTACK_ENDPOINT=true

exec 9>/run/ctech-lbalancer-reconcile.lock
flock -n 9 || exit 0

STATE_DIR=/var/lib/haproxy/ctech-state
CONFIG=/etc/haproxy/haproxy.cfg
mkdir -p "$STATE_DIR" /etc/haproxy/tls

parameter() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null
}

install_tls() {
  local cert key ca bundle_tmp ca_tmp
  cert=$(parameter '__TLS_CERTIFICATE_PATH__') || return 1
  key=$(parameter '__TLS_PRIVATE_KEY_PATH__') || return 1
  ca=$(parameter '__AOP_CA_PATH__') || return 1
  [ -n "$cert" ] && [ -n "$key" ] && [ -n "$ca" ] || return 1

  bundle_tmp=$(mktemp)
  ca_tmp=$(mktemp)
  printf '%s\n%s\n' "$cert" "$key" > "$bundle_tmp"
  printf '%s\n' "$ca" > "$ca_tmp"
  openssl x509 -in "$bundle_tmp" -noout -checkend 86400 >/dev/null
  openssl pkey -in "$bundle_tmp" -noout >/dev/null
  openssl x509 -in "$ca_tmp" -noout >/dev/null
  install -o root -g haproxy -m 0640 "$bundle_tmp" /etc/haproxy/tls/origin.pem
  install -o root -g haproxy -m 0640 "$ca_tmp" /etc/haproxy/tls/aop-ca.pem
  rm -f "$bundle_tmp" "$ca_tmp"
}

if ! install_tls; then
  echo 'TLS parameters are not ready; HAProxy remains stopped and the timer will retry' >&2
  exit 0
fi

routes=$(aws ssm get-parameters-by-path --path '__ROUTES_PATH__' --recursive \
  --output json | jq -ce '[.Parameters[].Value | fromjson]')

jq -e '
  all(.[];
    (.hostname | type == "string" and test("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")) and
    (.asg | type == "string" and test("^[A-Za-z0-9+=,.@_-]+$")) and
    (.port | type == "number" and . >= 1 and . <= 65535 and floor == .) and
    (.healthPath | type == "string" and test("^/[-A-Za-z0-9._~/?=&%]*$")) and
    (.healthyStatuses | type == "array" and length > 0 and all(.[]; type == "number" and . >= 100 and . <= 599)) and
    (.autoHeal | type == "boolean")
  ) and ([.[].hostname] | length == (unique | length))
' >/dev/null <<<"$routes"

mapfile -t asg_names < <(jq -r '.[].asg' <<<"$routes" | sort -u)
if [ "${#asg_names[@]}" -gt 0 ]; then
  groups=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "${asg_names[@]}" --output json)
else
  groups='{"AutoScalingGroups":[]}'
fi

mapfile -t instance_ids < <(jq -r '
  .AutoScalingGroups[].Instances[] |
  select(.LifecycleState == "InService" and .HealthStatus == "Healthy") |
  .InstanceId
' <<<"$groups" | sort -u)
if [ "${#instance_ids[@]}" -gt 0 ]; then
  instances=$(aws ec2 describe-instances --instance-ids "${instance_ids[@]}" --output json)
else
  instances='{"Reservations":[]}'
fi

resolved=$(jq -cn \
  --argjson routes "$routes" \
  --argjson groups "$groups" \
  --argjson instances "$instances" '
  [$routes[] as $route | $route + {targets: ([
    $groups.AutoScalingGroups[]
    | select(.AutoScalingGroupName == $route.asg)
    | .Instances[]
    | select(.LifecycleState == "InService" and .HealthStatus == "Healthy")
    | .InstanceId as $id
    | $instances.Reservations[].Instances[]
    | select(.InstanceId == $id and .State.Name == "running")
    | {id: .InstanceId, ip: .PrivateIpAddress, launchTime: .LaunchTime}
  ] | sort_by(.id))}] | sort_by(.hostname)
')

new_config=$(mktemp)
trap 'rm -f "$new_config"' EXIT
tls_fingerprint=$(sha256sum /etc/haproxy/tls/origin.pem /etc/haproxy/tls/aop-ca.pem | sha256sum | cut -d' ' -f1)
printf '# tls-fingerprint %s\n' "$tls_fingerprint" > "$new_config"
cat >> "$new_config" <<'HAPROXY'
global
  log 127.0.0.1:514 local2
  user haproxy
  group haproxy
  stats socket /run/haproxy/admin.sock mode 660 level admin
  maxconn 2048
  ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
  log global
  mode http
  option httplog
  option dontlognull
  option http-keep-alive
  timeout connect 5s
  timeout client 65s
  timeout server 65s
  timeout http-request 10s
  timeout http-keep-alive 15s
  timeout tunnel 1h
  retries 2
  http-error status 503 content-type application/json string '{"message": "Unavailable service"}'

frontend https
  bind :::443 v6only ssl strict-sni crt /etc/haproxy/tls/origin.pem ca-file /etc/haproxy/tls/aop-ca.pem verify required alpn h2,http/1.1
  capture request header Host len 128
  capture request header CF-Ray len 128
  http-request del-header Forwarded
  http-request del-header X-Forwarded-For
  http-request set-header X-Forwarded-For %[src]
  http-request set-header X-Forwarded-For %[req.hdr(CF-Connecting-IP)] if { req.hdr(CF-Connecting-IP) -m found }
  http-request set-header X-Real-IP %[req.hdr(CF-Connecting-IP)] if { req.hdr(CF-Connecting-IP) -m found }
  http-request set-header X-Forwarded-Proto https
  # Cloudflare terminates visitor TLS, then establishes a separate mutually
  # authenticated TLS connection to this frontend. The TLS fields below describe
  # that Cloudflare-to-HAProxy connection. The timers are HAProxy transaction
  # timers: they do not measure visitor-to-Cloudflare latency, while the queue,
  # connect, and response components isolate work after routing to a backend.
  # Do not log the URL, query, cookies, authorization headers, or client IPs.
  log-format "{\"status\":%ST,\"host\":\"%[capture.req.hdr(0),json(utf8s)]\",\"backend\":\"%b\",\"server\":\"%s\",\"bytes\":%B,\"http_method\":\"%HM\",\"http_version\":\"%HV\",\"cf_ray\":\"%[capture.req.hdr(1),json(utf8s)]\",\"tls_protocol\":\"%[ssl_fc_protocol,json(utf8s)]\",\"tls_cipher\":\"%[ssl_fc_cipher,json(utf8s)]\",\"request_receive_time_ms\":%TR,\"queue_time_ms\":%Tw,\"backend_connect_time_ms\":%Tc,\"backend_response_time_ms\":%Tr,\"total_time_ms\":%Ta,\"termination_state\":\"%tsc\"}"
HAPROXY

route_count=$(jq 'length' <<<"$resolved")
for ((index=0; index<route_count; index++)); do
  hostname=$(jq -r ".[${index}].hostname" <<<"$resolved")
  printf '  acl route_%d hdr(host),lower -i %s\n' "$index" "$hostname" >> "$new_config"
  printf '  use_backend route_%d if route_%d\n' "$index" "$index" >> "$new_config"
done
cat >> "$new_config" <<'HAPROXY'
  default_backend unknown_host

frontend local_stats
  bind 127.0.0.1:8404
  http-request use-service prometheus-exporter if { path /metrics }
  stats enable
  stats uri /stats
  stats refresh 10s

backend unknown_host
  http-request return status 421 content-type application/json string '{"message":"Unknown host"}'
HAPROXY

for ((index=0; index<route_count; index++)); do
  hostname=$(jq -r ".[${index}].hostname" <<<"$resolved")
  port=$(jq -r ".[${index}].port" <<<"$resolved")
  health_path=$(jq -r ".[${index}].healthPath" <<<"$resolved")
  statuses=$(jq -r --argjson index "$index" \
    '.[$index].healthyStatuses | map(tostring) | join("|")' <<<"$resolved")
  cat >> "$new_config" <<HAPROXY

backend route_${index}
  balance roundrobin
  option httpchk
  http-check send meth GET uri ${health_path} ver HTTP/1.1 hdr Host ${hostname}
  http-check expect rstatus ^(${statuses})$
  default-server check inter 5s fall 3 rise 2 slowstart 10s
HAPROXY
  target_count=$(jq ".[${index}].targets | length" <<<"$resolved")
  for ((target_index=0; target_index<target_count; target_index++)); do
    instance_id=$(jq -r ".[${index}].targets[${target_index}].id" <<<"$resolved")
    private_ip=$(jq -r ".[${index}].targets[${target_index}].ip" <<<"$resolved")
    printf '  server %s %s:%s\n' "$instance_id" "$private_ip" "$port" >> "$new_config"
  done
done

/usr/local/sbin/haproxy -c -f "$new_config"
if [ ! -f "$CONFIG" ] || ! cmp -s "$new_config" "$CONFIG"; then
  install -o root -g haproxy -m 0640 "$new_config" "$CONFIG"
  if systemctl is-active --quiet haproxy; then
    systemctl reload haproxy
  else
    systemctl enable --now haproxy
  fi
fi

# App-level auto-healing: HAProxy immediately stops routing after its own fall
# threshold. Three failed reconciliations then mark only the stuck ASG instance
# unhealthy, so the ASG replaces it. The 3-minute launch guard prevents loops.
now=$(date +%s)
for ((index=0; index<route_count; index++)); do
  auto_heal=$(jq -r ".[${index}].autoHeal" <<<"$resolved")
  [ "$auto_heal" = 'true' ] || continue
  hostname=$(jq -r ".[${index}].hostname" <<<"$resolved")
  port=$(jq -r ".[${index}].port" <<<"$resolved")
  health_path=$(jq -r ".[${index}].healthPath" <<<"$resolved")
  target_count=$(jq ".[${index}].targets | length" <<<"$resolved")
  for ((target_index=0; target_index<target_count; target_index++)); do
    instance_id=$(jq -r ".[${index}].targets[${target_index}].id" <<<"$resolved")
    private_ip=$(jq -r ".[${index}].targets[${target_index}].ip" <<<"$resolved")
    launch_time=$(jq -r ".[${index}].targets[${target_index}].launchTime" <<<"$resolved")
    launched=$(date -d "$launch_time" +%s)
    [ $((now - launched)) -ge 180 ] || continue
    code=$(curl --silent --output /dev/null --connect-timeout 3 --max-time 5 \
      --header "Host: ${hostname}" --write-out '%{http_code}' \
      "http://${private_ip}:${port}${health_path}" || true)
    if jq -e --arg code "${code:-0}" ".[${index}].healthyStatuses | index(\$code | tonumber) != null" \
      >/dev/null <<<"$resolved"; then
      rm -f "$STATE_DIR/${instance_id}.failures"
      continue
    fi
    failures=0
    [ ! -f "$STATE_DIR/${instance_id}.failures" ] || failures=$(cat "$STATE_DIR/${instance_id}.failures")
    failures=$((failures + 1))
    printf '%s\n' "$failures" > "$STATE_DIR/${instance_id}.failures"
    if [ "$failures" -ge 3 ]; then
      aws autoscaling set-instance-health --instance-id "$instance_id" \
        --health-status Unhealthy --should-respect-grace-period
      rm -f "$STATE_DIR/${instance_id}.failures"
      echo "Marked unhealthy target ${instance_id} after ${failures} failed checks" >&2
    fi
  done
done

# Publish this ASG member's current IPv6 for operations and optionally maintain
# the one DNS-only origin AAAA record. Public hostnames remain proxied CNAMEs.
imds_token=$(curl --silent --fail --max-time 2 -X PUT \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
  http://169.254.169.254/latest/api/token || true)
if [ -n "$imds_token" ]; then
  mac=$(curl --silent --fail --max-time 2 -H "X-aws-ec2-metadata-token: ${imds_token}" \
    http://169.254.169.254/latest/meta-data/mac || true)
  ipv6=$(curl --silent --fail --max-time 2 -H "X-aws-ec2-metadata-token: ${imds_token}" \
    "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${mac}/ipv6s" \
    | head -n 1 || true)
  if [ -n "$ipv6" ]; then
    aws ssm put-parameter --name '__ORIGIN_IPV6_PATH__' --type String \
      --value "$ipv6" --overwrite >/dev/null
    if [ -n '__CLOUDFLARE_ZONE_ID__' ]; then
      cf_token=$(parameter '__CLOUDFLARE_TOKEN_PATH__' || true)
      if [ -n "$cf_token" ]; then
        api="https://api.cloudflare.com/client/v4/zones/__CLOUDFLARE_ZONE_ID__/dns_records"
        if record=$(curl --fail --silent --show-error --max-time 10 \
            -H "Authorization: Bearer ${cf_token}" \
            "${api}?type=AAAA&name=__ORIGIN_DOMAIN__"); then
          record_id=$(jq -r '.result[0].id // empty' <<<"$record")
          old_content=$(jq -r '.result[0].content // empty' <<<"$record")
          old_proxied=$(jq -r '.result[0].proxied // empty' <<<"$record")
          body=$(jq -cn --arg name '__ORIGIN_DOMAIN__' --arg content "$ipv6" \
            '{type:"AAAA",name:$name,content:$content,ttl:60,proxied:false}')
          if [ -n "$record_id" ] && \
              { [ "$old_content" != "$ipv6" ] || [ "$old_proxied" != 'false' ]; }; then
            curl --fail --silent --show-error --max-time 10 -X PUT \
              -H "Authorization: Bearer ${cf_token}" \
              -H 'Content-Type: application/json' --data "$body" \
              "${api}/${record_id}" >/dev/null || \
              echo 'Cloudflare origin AAAA update failed; HAProxy remains active' >&2
          elif [ -z "$record_id" ]; then
            curl --fail --silent --show-error --max-time 10 -X POST \
              -H "Authorization: Bearer ${cf_token}" \
              -H 'Content-Type: application/json' --data "$body" "$api" >/dev/null || \
              echo 'Cloudflare origin AAAA creation failed; HAProxy remains active' >&2
          fi
        else
          echo 'Cloudflare origin AAAA lookup failed; HAProxy remains active' >&2
        fi
      fi
    fi
  fi
fi
