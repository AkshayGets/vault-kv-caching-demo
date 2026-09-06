#!/usr/bin/env bash
# Install Vault Proxy and the demo application onto the EC2 host, over SSM.
# The host is the one built by the AWS EC2 implementation - nothing new is launched.
set -euo pipefail
export AWS_PROFILE="${EC2_PROFILE:-iam-account}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_TAG="${NAME_TAG:-vault-ec2-demo}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

IID=$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=$NAME_TAG" "Name=instance-state-name,Values=running" \
      --query 'Reservations[0].Instances[0].InstanceId' --output text)
[[ -z "$IID" || "$IID" == "None" ]] && { echo "no running instance tagged $NAME_TAG"; exit 1; }
echo "instance: $IID"

python3 - "$HERE" <<'PY' > /tmp/kv-deploy.json
import base64, json, sys, os
here = sys.argv[1]
files = {
    "/etc/vault-proxy/proxy.hcl":                    f"{here}/vault-proxy/proxy.hcl",
    "/etc/systemd/system/vault-proxy.service":       f"{here}/vault-proxy/vault-proxy.service",
    "/etc/systemd/system/kv-demo-app.service":       f"{here}/vault-proxy/kv-demo-app.service",
    "/opt/kv-demo/app.py":                           f"{here}/app/app.py",
}
cmds = ["install -d -o demoapp -g demoapp -m 0750 /etc/vault-proxy",
        "install -d -o demoapp -g demoapp -m 0755 /opt/kv-demo"]
for dest, src in files.items():
    b64 = base64.b64encode(open(src, "rb").read()).decode()
    tmp = "/tmp/" + dest.replace("/", "_") + ".b64"
    cmds.append(f"rm -f {tmp}")
    cmds += [f"printf '%s' '{b64[i:i+3000]}' >> {tmp}" for i in range(0, len(b64), 3000)]
    cmds += [f"base64 -d {tmp} > {dest}", f"rm -f {tmp}"]
cmds += ["chown -R demoapp:demoapp /etc/vault-proxy /opt/kv-demo",
         "chmod 0640 /etc/vault-proxy/proxy.hcl",
         "python3 -m py_compile /opt/kv-demo/app.py && echo 'app compiles'",
         "systemctl daemon-reload",
         "systemctl enable --now vault-proxy", "sleep 6",
         "systemctl enable --now kv-demo-app",  "sleep 3",
         "systemctl is-active vault-proxy kv-demo-app"]
json.dump({"commands": cmds}, open("/dev/stdout", "w"))
PY

CMD=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
      --parameters file:///tmp/kv-deploy.json --query 'Command.CommandId' --output text)
for _ in $(seq 1 30); do
  S=$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$IID" --query Status --output text 2>/dev/null || echo Pending)
  [[ "$S" == Success || "$S" == Failed ]] && break; sleep 5
done
echo "[$S]"
aws ssm get-command-invocation --command-id "$CMD" --instance-id "$IID" --query StandardOutputContent --output text
aws ssm get-command-invocation --command-id "$CMD" --instance-id "$IID" --query StandardErrorContent --output text | head -20
