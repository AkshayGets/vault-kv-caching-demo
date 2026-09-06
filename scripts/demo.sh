#!/usr/bin/env bash
# KV static-secret caching demo (Vault Proxy).  Usage: ./scripts/demo.sh <command>
set -euo pipefail

# The demo host lives in the IAM account. A dedicated variable, so an AWS_PROFILE
# exported for another account cannot be picked up here by mistake.
export AWS_PROFILE="${EC2_PROFILE:-iam-account}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export VAULT_ADDR="${VAULT_ADDR:-https://vault.example.com}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-apps}"
NAME_TAG="${NAME_TAG:-vault-ec2-demo}"
APP_PORT=8090                              # on the instance
LOCAL_PORT="${LOCAL_PORT:-8083}"           # AWS demos use 8080-8082
HERE="$(cd "$(dirname "$0")/.." && pwd)"

iid() {
  local id
  id=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$NAME_TAG" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
  if [[ -z "$id" || "$id" == "None" ]]; then
    cat >&2 <<EOF
No running instance tagged "$NAME_TAG" is visible.
  profile : $AWS_PROFILE  (account $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '?'))
  region  : $AWS_REGION
This demo runs on the host built by the AWS EC2 implementation. Override the tag with
NAME_TAG=... or the profile with EC2_PROFILE=... .
EOF
    exit 1
  fi
  printf '%s' "$id"
}

ssm_run() {
  local id cmd status
  id=$(iid)
  cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
        --parameters "commands=$1" --query 'Command.CommandId' --output text)
  for _ in $(seq 1 30); do
    status=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
             --query 'Status' --output text 2>/dev/null || echo Pending)
    [[ "$status" == "Success" || "$status" == "Failed" ]] && break
    sleep 4
  done
  aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
      --query 'StandardOutputContent' --output text
  aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
      --query 'StandardErrorContent' --output text | sed '/^$/d'
}

case "${1:-help}" in

start)   # port-forward the page over SSM - no inbound ports, no SSH key
  echo "Opening http://localhost:${LOCAL_PORT} ...   Ctrl-C to stop."
  aws ssm start-session --target "$(iid)" \
    --document-name AWS-StartPortForwardingSession \
    --parameters "{\"portNumber\":[\"${APP_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
  ;;

cold)    # RUN THIS BEFORE DEMONSTRATING
  # Restarting the proxy empties its cache, so the next read of each tenant is a
  # genuine miss that travels to Vault. Without this the cache may already be warm
  # from an earlier run and every read looks fast.
  echo "Emptying the proxy cache and clearing the app's history..."
  ssm_run '["systemctl restart vault-proxy","sleep 5","curl -s -o /dev/null -X POST http://127.0.0.1:8090/api/reset","systemctl is-active vault-proxy kv-demo-app"]'
  echo "Cold. The first read of each tenant will now reach Vault."
  ;;

fetch)   # ./scripts/demo.sh fetch acme  - same call the page makes
  t="${2:-acme}"
  ssm_run "[\"curl -s -o /dev/null -w 'HTTP %{http_code}  %{time_total}s\\n' -X POST http://127.0.0.1:8090/api/fetch?tenant=$t\"]"
  ;;

compare) # the whole point, on one screen
  ssm_run '["systemctl restart vault-proxy","sleep 5","curl -s -o /dev/null -X POST http://127.0.0.1:8090/api/reset","echo \"tenant   read      latency\"","curl -s -o /dev/null -w \"acme     1st (Vault)   %{time_total}s\\n\" -X POST http://127.0.0.1:8090/api/fetch?tenant=acme","curl -s -o /dev/null -w \"acme     2nd (cache)   %{time_total}s\\n\" -X POST http://127.0.0.1:8090/api/fetch?tenant=acme","curl -s -o /dev/null -w \"acme     3rd (cache)   %{time_total}s\\n\" -X POST http://127.0.0.1:8090/api/fetch?tenant=acme","curl -s -o /dev/null -w \"globex   1st (Vault)   %{time_total}s\\n\" -X POST http://127.0.0.1:8090/api/fetch?tenant=globex","curl -s -o /dev/null -w \"globex   2nd (cache)   %{time_total}s\\n\" -X POST http://127.0.0.1:8090/api/fetch?tenant=globex"]'
  ;;

noproxy) # prove the app carries no credential of its own
  echo "--- the app container's Vault-related environment ---"
  ssm_run '["systemctl show kv-demo-app -p Environment --no-pager","echo","echo \"the same request WITHOUT the proxy attaching a token:\"","curl -s -o /dev/null -w \"direct to Vault: HTTP %{http_code}\\n\" -H \"X-Vault-Request: true\" -H \"X-Vault-Namespace: apps\" https://vault.example.com/v1/kv-demo/data/tenants/acme/api-key"]'
  ;;

status)
  echo "instance: $(iid)"
  ssm_run '["systemctl is-active vault-proxy kv-demo-app","echo","systemctl status vault-proxy --no-pager -n 0 | head -6"]'
  ;;

logs)    # the proxy: login, renewals, cache subsystem
  ssm_run '["journalctl -u vault-proxy --no-pager -n 40"]'
  ;;

applogs)
  ssm_run '["journalctl -u kv-demo-app --no-pager -n 30"]'
  ;;

config)  # the proxy configuration in force
  ssm_run '["cat /etc/vault-proxy/proxy.hcl"]'
  ;;

secrets) # what is in KV, from your machine
  echo "--- tenants ---"; vault kv list kv-demo/tenants
  echo "--- acme (values masked) ---"
  vault kv get -format=json kv-demo/tenants/acme/api-key \
    | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print("version",d["metadata"]["version"],"| keys",list(d["data"]))'
  ;;

rotate)  # change a secret and watch the cache pick it up without polling
  t="${2:-acme}"
  vault kv put "kv-demo/tenants/$t/api-key" \
      value="sk-$t-$(openssl rand -hex 6)" tenant="$t" \
      downstream="https://api.$t.example.com" >/dev/null
  echo "Rotated $t in Vault. Re-read it on the page - the value and kv version change,"
  echo "because Vault Proxy is subscribed to KV events and evicted its cached copy."
  ;;

session)
  aws ssm start-session --target "$(iid)"
  ;;

reload)  # push local app/app.py to the instance
  python3 - "$HERE/app/app.py" <<'PY' > /tmp/kv-params.json
import base64, json, sys
b64 = base64.b64encode(open(sys.argv[1], "rb").read()).decode()
cmds = ["rm -f /tmp/kv.b64"]
cmds += [f"printf '%s' '{b64[i:i+3000]}' >> /tmp/kv.b64" for i in range(0, len(b64), 3000)]
cmds += ["base64 -d /tmp/kv.b64 > /opt/kv-demo/app.py",
         "chown demoapp:demoapp /opt/kv-demo/app.py",
         "python3 -m py_compile /opt/kv-demo/app.py && echo compiled",
         "systemctl restart kv-demo-app", "sleep 4", "systemctl is-active kv-demo-app"]
json.dump({"commands": cmds}, open("/dev/stdout", "w"))
PY
  id=$(iid)
  cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
        --parameters file:///tmp/kv-params.json --query 'Command.CommandId' --output text)
  for _ in $(seq 1 30); do
    s=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
    [[ "$s" == Success || "$s" == Failed ]] && break; sleep 4
  done
  echo "[$s]"
  aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" --query StandardOutputContent --output text
  ;;

remove)  # take this demo off the host, leaving the AWS demo and the instance running
  read -rp "Remove the KV demo from the instance? (the host and the AWS demo stay) [y/N] " ok
  [[ "$ok" == y || "$ok" == Y ]] || { echo aborted; exit 0; }
  ssm_run '["systemctl disable --now kv-demo-app vault-proxy","rm -rf /opt/kv-demo /etc/vault-proxy /etc/systemd/system/kv-demo-app.service /etc/systemd/system/vault-proxy.service","systemctl daemon-reload","echo removed"]'
  echo "Vault objects left in place. Remove with:"
  echo "  vault secrets disable kv-demo"
  echo "  vault policy delete kv-demo-policy"
  echo "  vault delete auth/aws-ec2/role/kv-demo-app"
  ;;

*)
  cat <<'EOF'
KV static-secret caching with Vault Proxy - demo helper

  ./scripts/demo.sh cold       empty the proxy cache   <-- RUN THIS FIRST
  ./scripts/demo.sh start      port-forward the page to localhost:8083
  ./scripts/demo.sh compare    first read vs cached read, side by side, in one command
  ./scripts/demo.sh rotate acme  change the secret in Vault; the cache evicts on the event
  ./scripts/demo.sh noproxy    show the app holds no token, and what happens without one
  ./scripts/demo.sh secrets    what is in KV
  ./scripts/demo.sh fetch acme  one read, from the command line
  ./scripts/demo.sh status     service state
  ./scripts/demo.sh logs       the proxy log: auth, renewals, cache subsystem
  ./scripts/demo.sh applogs    the application log
  ./scripts/demo.sh config     the proxy configuration on the host
  ./scripts/demo.sh session    interactive shell on the instance
  ./scripts/demo.sh reload     push local app/app.py to the instance
  ./scripts/demo.sh remove     remove this demo from the host

Runs on the instance built by the AWS EC2 implementation. No inbound ports; access
is through SSM Session Manager.
EOF
  ;;
esac
