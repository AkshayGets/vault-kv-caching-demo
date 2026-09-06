# Caching KV secrets with Vault Proxy

When an application reads a secret whose path is only known at request time, it cannot be
rendered to a file in advance. This is a working implementation of that case: a multi-tenant
service that calls Vault's API for a per-tenant secret, with **Vault Proxy** supplying the token
and caching the responses.

The application still contains no authentication code, no token handling and no caching logic.

> **The distinction that matters.** Vault Agent renders secrets to files, and that is the right
> answer whenever the set of secrets is known at deploy time. It cannot help here, and — more
> importantly — **Vault Agent does not cache KV secrets at all**. Its cache covers tokens and
> *leased* secrets; KV is static and carries no lease. Static secret caching is a Vault Proxy
> capability.

---

## Placeholder values

Every environment-specific value in this repository is a placeholder. Replace them before
running anything.

| Placeholder | What it stands for |
|---|---|
| `vault.example.com` | Your Vault address |
| `apps` | Vault namespace holding the mounts |
| `111122223333` | AWS account holding the IAM role |
| `ec2-demo-role` | IAM role attached to the instance — its identity |
| `aws-ec2` | Mount path of the AWS auth method |
| `vault-ec2-demo` | `Name` tag of the EC2 host |
| `kv-demo` | Mount path of the KV v2 secrets engine |
| `kv-demo-app` | The Vault auth role this application logs in as |
| `kv-demo-policy` | The Vault policy granting the reads and the event subscription |
| `demoapp` | The unprivileged Linux user the proxy and application run as |

---

## 1. Why this application calls the API

A request arrives naming a tenant. Only then does the application know which secret it needs:

```
kv-demo/data/tenants/acme/api-key
kv-demo/data/tenants/globex/api-key
kv-demo/data/tenants/initech/api-key
```

With four thousand tenants you would need four thousand rendered files, re-rendered whenever a
tenant is added — and the application would still have to choose one. The path is data, not
configuration, so it has to be requested.

Other cases with the same shape: an application that **writes** to Vault, one that uses
**transit** encryption or issues **PKI** certificates for a hostname decided at runtime, and any
existing application already built around a Vault client library that you would rather not
rewrite.

### Agent or Proxy?

| | Vault Agent | Vault Proxy |
|---|---|---|
| Auto-auth | yes | yes |
| Rendering secrets to files | **yes — Agent only** | no |
| API proxy and caching | yes, but deprecation announced | yes — this is its purpose |
| **Caching KV (static) secrets** | **no** | **yes — Proxy only** |

This implementation uses **Vault Proxy**. The
[AWS implementations](https://github.com/AkshayGets/vault-aws-secrets-demo) use Vault Agent,
because there the secrets are known at deploy time and rendering them to files means the
application contains no Vault code whatsoever.

---

## 2. What runs where

```
        EC2 instance
 ┌───────────────────────────────────────────────┐
 │  application  (port 8090)                     │      ┌──────────────┐
 │      │  GET /v1/kv-demo/data/tenants/acme/... │      │              │
 │      │  no token, no login                    │      │    Vault     │
 │      ▼                                        │      │              │
 │  Vault Proxy  (127.0.0.1:8200)  ──────────────┼─────▶│  kv-demo/    │
 │      · attaches its auto-auth token           │      │              │
 │      · serves repeat reads from cache         │◀─────┤  KV events   │
 │      · subscribes to KV events                │      └──────────────┘
 └───────────────────────────────────────────────┘
```

The proxy authenticates with the **instance's IAM role**, exactly as Vault Agent does on the
same host. Nothing new is launched: this runs on the instance built by the
[EC2 implementation](https://github.com/AkshayGets/vault-aws-secrets-demo/tree/master/ec2), and
the two coexist — Vault Agent rendering AWS credentials to files, Vault Proxy serving KV over
the API.

---

## 3. Prerequisites

- **Vault Enterprise.** Static secret caching relies on Vault's event notification system, which
  is an Enterprise capability.
- An **EC2 instance with an instance profile**, and the **AWS auth method** configured so that
  instance can log in. If you do not already have one, sections 3 to 7 of the
  [EC2 implementation](https://github.com/AkshayGets/vault-aws-secrets-demo/tree/master/ec2)
  build exactly that, and this demo reuses it unchanged.
- The `vault` binary on the instance — the same binary provides `vault agent` and `vault proxy`.
- **AWS Systems Manager** for access without opening an inbound port.

This guide stands on its own: if you follow the EC2 implementation first, every prerequisite
here is already satisfied and you can start at section 4.

---

## 4. Configure Vault

Run [`vault/setup.sh`](vault/setup.sh), or the steps individually:

```bash
export VAULT_ADDR=https://vault.example.com
export VAULT_NAMESPACE=apps
```

### 4.1 A KV v2 mount, and some tenants

```bash
vault secrets enable -path=kv-demo -version=2 kv

for t in acme globex initech; do
  vault kv put "kv-demo/tenants/$t/api-key" \
      value="sk-${t}-$(openssl rand -hex 6)" \
      tenant="$t" \
      downstream="https://api.${t}.example.com"
done
```

### 4.2 The policy — and why it is larger than you would expect

```bash
vault policy write kv-demo-policy - <<'EOF'
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
EOF
```

Only the first block is about reading secrets. The rest is what makes the cache trustworthy:

- **`subscribe` plus `sys/events/subscribe/kv*`** let the proxy subscribe to Vault's event feed
  and be told when a cached secret changes. This is why the cache does not go stale and why
  there is no refresh interval to tune.
- **`sys/capabilities-self`** lets the proxy periodically re-check that its token is *still*
  permitted to read what it is holding. Revoke the policy and the cached copy stops being
  served, rather than surviving until something expires.

### 4.3 An auth role for the application

```bash
vault write auth/aws-ec2/role/kv-demo-app \
    auth_type=iam \
    bound_iam_principal_arn="arn:aws:iam::111122223333:role/ec2-demo-role" \
    resolve_aws_unique_ids=false \
    token_policies=kv-demo-policy \
    token_ttl=1h
```

The same instance identity as the AWS demo, with a different policy. The instance proves who it
is with its IAM role; what it may then read is decided entirely by the Vault role.

---

## 5. Deploy the proxy and the application

```bash
./scripts/deploy.sh
```

It copies four files onto the instance over SSM and starts two services — no inbound port, no
SSH key:

| File | Purpose |
|---|---|
| `/etc/vault-proxy/proxy.hcl` | the proxy configuration |
| `/etc/systemd/system/vault-proxy.service` | runs `vault proxy`, as `demoapp` |
| `/etc/systemd/system/kv-demo-app.service` | runs the application, as `demoapp` |
| `/opt/kv-demo/app.py` | the application |

---

## 6. The proxy configuration

[`vault-proxy/proxy.hcl`](vault-proxy/proxy.hcl):

```hcl
vault {
  address   = "https://vault.example.com"
  namespace = "apps"
}

auto_auth {
  method "aws" {
    mount_path = "auth/aws-ec2"
    config = { type = "iam", role = "kv-demo-app", region = "us-east-1" }
  }
  sink "file" { config = { path = "/etc/vault-proxy/token" } }
}

cache {
  cache_static_secrets                            = true
  static_secret_token_capability_refresh_interval = "5m"
}

api_proxy {
  use_auto_auth_token = true
}

listener "tcp" {
  address                = "127.0.0.1:8200"
  tls_disable            = true
  require_request_header = true
}
```

Four things are load-bearing:

- **`cache_static_secrets = true`** is the whole point. Without it the cache still works, but
  only for tokens and leased secrets — every KV read would travel to Vault.
- **`use_auto_auth_token = true`** means the proxy attaches its own token to requests that
  arrive without one. This is why the application carries no credential. Setting it to
  `"force"` overrides any token the application does send.
- **`require_request_header = true`** requires callers to send `X-Vault-Request: true`. Official
  Vault clients do this automatically; a hand-written `curl` must add it.
- The listener binds to **`127.0.0.1`**, so nothing off the host can reach the proxy — which
  matters, because the proxy will attach a valid token to anything that does.

---

## 7. What the application does, and does not

[`app/app.py`](app/app.py) makes one kind of call:

```python
req = urllib.request.Request(f"{VAULT_ADDR}/v1/{KV_MOUNT}/data/tenants/{tenant}/api-key")
req.add_header("X-Vault-Request", "true")
# deliberately NO X-Vault-Token: the proxy supplies it
```

`VAULT_ADDR` is `http://127.0.0.1:8200`. That is the entire integration.

It does **not** authenticate, hold or renew a token, or cache anything. It is a plain HTTP GET
against loopback. The difference between this and the file-based implementations is that the
application knows Vault's *paths* — not that it has taken on any of Vault's plumbing.

---

## 8. Running the demo

```bash
./scripts/demo.sh cold      # RUN THIS FIRST - empties the proxy cache
./scripts/demo.sh start     # port-forward the page to http://localhost:8083
```

**Run `cold` before demonstrating.** Restarting the proxy empties its cache, so the first read
of each tenant is a genuine miss. Without it, a cache warmed by an earlier run makes every read
fast and the comparison disappears.

### The sequence to walk through

**Open with the top panel — "What this application knows about Vault".** One address, one path
shape, and `Token in this process: none`.

**Click a tenant once.** The proxy has to ask Vault. The card shows the latency and marks it
*fetched from Vault*.

**Click the same tenant again.** *Served by the proxy cache*, and roughly ten times faster. The
history table makes the pattern obvious as you go.

**Explain why templating could not do this**: the path contains the tenant, and the tenant is
not known until the request arrives.

**Then change the secret in Vault:**

```bash
./scripts/demo.sh rotate acme
```

Re-read `acme` on the page. The value and the KV version have changed — **without polling**. The
proxy is subscribed to Vault's KV events, so it refreshed its copy the moment the secret changed
— the first read of the new value is still a cache hit. Prove it with `./scripts/demo.sh watch acme`.
That is the part a hand-written cache almost never gets right, and it is worth pausing on.

### Everything in one command

```bash
$ ./scripts/demo.sh compare

tenant   read          latency
acme     1st (Vault)   0.018750s
acme     2nd (cache)   0.002545s
acme     3rd (cache)   0.001905s
globex   1st (Vault)   0.019041s
globex   2nd (cache)   0.001962s
```

> **Be honest about the numbers.** The instance and Vault are in the same region, so the
> uncached read is already fast in absolute terms — the ratio is what matters, and it grows
> considerably across regions or to an on-premises Vault. The more valuable saving is usually
> **load on Vault**: with the cache, one read per secret per proxy rather than one per request.

---

## 9. Other commands

```bash
./scripts/demo.sh noproxy    # the app's environment, and what a request without a token gets
./scripts/demo.sh secrets    # what is in KV
./scripts/demo.sh fetch acme # a single read, from the command line
./scripts/demo.sh logs       # the proxy: auth, renewals, cache subsystem
./scripts/demo.sh config     # the proxy configuration on the host
./scripts/demo.sh status     # service state
./scripts/demo.sh session    # shell on the instance
./scripts/demo.sh reload     # push a local app/app.py change
./scripts/demo.sh remove     # remove this demo, leaving the host and the AWS demo intact
```

A healthy proxy start looks like this:

```
proxy.cache: cache configured: cache_static_secrets=true disable_caching_dynamic_secrets=false
proxy.cache.staticsecretcacheupdater: starting static secret cache updater subsystem
proxy.auth.handler: authentication successful, sending token to sinks
proxy.sink.file: token written: path=/etc/vault-proxy/token
```

The two cache lines are the ones to check if reads are not being cached.

---

## 10. Security notes

- The application holds **no Vault token**. The proxy attaches one, and the token file
  (`/etc/vault-proxy/token`) is readable only by `demoapp`.
- The listener is bound to **loopback only**. It attaches a valid token to any request it
  accepts, so it must never be exposed off the host.
- The Vault token is short-lived (1h) and renewed by the proxy.
- The policy grants read on the tenant paths and nothing else. The event-subscription
  permissions carry no ability to read secrets on their own.
- `static_secret_token_capability_refresh_interval` means a revoked policy takes effect in the
  cache, not only at Vault.
- The cache is held **in memory**. Stopping the proxy discards it.
- The instance has no inbound security-group rules; access is through SSM Session Manager.

---

## 11. What is in this repository

```
app/app.py                        the application - no auth, no token, no caching logic
vault-proxy/proxy.hcl             the proxy configuration; this is the integration
vault-proxy/*.service             systemd units for the proxy and the application
vault/setup.sh                    creates the KV mount, tenants, policy and auth role
scripts/deploy.sh                 installs the proxy and application onto the instance
scripts/demo.sh                   cold / start / compare / rotate / logs / remove
```

---

## Related

**[vault-aws-secrets-demo](https://github.com/AkshayGets/vault-aws-secrets-demo)** — delivering
AWS credentials with no secrets in the application, in three forms:

- [`kubernetes-agent-injector/`](https://github.com/AkshayGets/vault-aws-secrets-demo/tree/master/kubernetes-agent-injector)
  — a sidecar renders credentials to files.
- [`ec2/`](https://github.com/AkshayGets/vault-aws-secrets-demo/tree/master/ec2) — Vault Agent
  under systemd does the same on a virtual machine. **This demo runs on that host**, and its
  sections 3 to 7 build the instance, the AWS auth method and the IAM role that are prerequisites
  here.
- [`kubernetes-direct-api/`](https://github.com/AkshayGets/vault-aws-secrets-demo/tree/master/kubernetes-direct-api)
  — the application calls Vault's API directly, with no daemon at all.

Those show the file-based pattern, where the application contains no Vault code. This one shows
what to do when the file-based pattern cannot apply.
