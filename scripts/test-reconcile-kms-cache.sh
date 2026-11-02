#!/bin/bash
# Guards the KMS policy of both reconcile templates: parameter() must decrypt a
# SecureString once per change, not once per 30s loop. Fakes the SSM clients.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"; echo 1 > "$WORK/ver"
cat > "$WORK/bin/aws" <<'FAKE'
#!/bin/bash
case "$*" in *with-decryption*) echo D >> "$CALLS"; printf 'plain-%s' "$(cat "$VER")";; *) printf 'cipher-%s' "$(cat "$VER")";; esac
FAKE
cat > "$WORK/bin/ctech-ec2-agent" <<'FAKE'
#!/bin/bash
case "$*" in *decrypt=false*) printf 'cipher-%s' "$(cat "$VER")";; *) echo D >> "$CALLS"; printf 'plain-%s' "$(cat "$VER")";; esac
FAKE
chmod +x "$WORK"/bin/*
export PATH="$WORK/bin:$PATH" VER="$WORK/ver" CALLS="$WORK/calls"

for tpl in reconcile.sh.tftpl reconcile-alpine.sh.tftpl; do
  : > "$CALLS"; echo 1 > "$VER"; rm -rf "$WORK/cache"
  awk '/^parameter\(\)/,/^}/' "$ROOT/assets/$tpl" | sed "s#/run/ctech-ssm#$WORK/cache#" > "$WORK/fn.sh"
  # shellcheck disable=SC1091
  . "$WORK/fn.sh"
  for _ in 1 2 3; do [ "$(parameter /p)" = plain-1 ] || { echo "$tpl: wrong value"; exit 1; }; done
  decrypts=$(grep -c D "$CALLS" || true)
  [ "$decrypts" = 1 ] || { echo "$tpl: $decrypts decrypting reads for 3 loops, want 1"; exit 1; }
  echo 2 > "$VER"
  [ "$(parameter /p)" = plain-2 ] || { echo "$tpl: rotation not picked up"; exit 1; }
  echo "ok $tpl"
done
