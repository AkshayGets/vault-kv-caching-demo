#!/usr/bin/env bash
# Vault objects for the KV caching demo. Run once.
set -euo pipefail
export VAULT_ADDR="${VAULT_ADDR:-https://vault.example.com}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-apps}"
: "${VAULT_TOKEN:?set VAULT_TOKEN}"
INSTANCE_ROLE_ARN="${INSTANCE_ROLE_ARN:-arn:aws:iam::111122223333:role/ec2-demo-role}"

echo "=== 1/4  KV v2 mount ==="
vault secrets enable -path=kv-demo -version=2 kv 2>/dev/null || echo "  kv-demo already enabled"

echo "=== 2/4  seed tenants ==="
for t in acme globex initech; do
  vault kv put "kv-demo/tenants/$t/api-key" \
      value="sk-${t}-$(openssl rand -hex 6)" \
      tenant="$t" \
      downstream="https://api.${t}.example.com" >/dev/null
  echo "  $t"
done

echo "=== 3/4  policy ==="
# 'subscribe' and the sys/events path are what static secret caching needs: the proxy
# watches for changes instead of polling. sys/capabilities-self lets it re-check that
# it is still allowed to read what it has cached.
vault policy write kv-demo-policy - <<'POLICY' >/dev/null
path "kv-demo/data/tenants/*" {
  capabilities          = ["read", "subscribe"]
  subscribe_event_types = ["*"]
}
path "kv-demo/metadata/tenants/*" {
  capabilities = ["read", "list"]
}
path "sys/events/subscribe/kv*" {
  capabilities = ["read"]
}
path "sys/capabilities-self" {
  capabilities = ["update"]
}
POLICY
echo "  kv-demo-policy"

echo "=== 4/4  auth role (same instance identity as the AWS EC2 demo) ==="
vault write auth/aws-ec2/role/kv-demo-app \
  auth_type=iam \
  bound_iam_principal_arn="$INSTANCE_ROLE_ARN" \
  resolve_aws_unique_ids=false \
  token_policies=kv-demo-policy \
  token_ttl=1h >/dev/null
echo "  auth/aws-ec2/role/kv-demo-app"
echo
echo "Done. Deploy the proxy and app with ./scripts/deploy.sh"
