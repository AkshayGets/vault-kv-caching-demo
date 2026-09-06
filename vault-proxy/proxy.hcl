# Vault Proxy - the API-proxy and caching counterpart to Vault Agent.
#
# Vault Agent renders secrets to files. Vault Proxy does the opposite job: it lets
# an application call Vault's API normally, while the proxy supplies the token and
# caches the responses. Static (KV) secret caching is Proxy-only - Vault Agent does
# not support it with its API proxy.

vault {
  address   = "https://vault.example.com"
  namespace = "apps"
}

# Same machine identity as everything else on this host: the instance's IAM role.
auto_auth {
  method "aws" {
    mount_path = "auth/aws-ec2"
    config = {
      type   = "iam"
      role   = "kv-demo-app"
      region = "us-east-1"
    }
  }
  sink "file" {
    config = { path = "/etc/vault-proxy/token" }
  }
}

cache {
  # KV v1/v2 responses are cached here. Without this, every read from the
  # application would still travel to Vault - the token cache alone does not
  # cover static secrets.
  cache_static_secrets = true

  # How often the proxy re-checks that its token is still allowed to read what it
  # has cached, so a revoked policy takes effect in the cache too.
  static_secret_token_capability_refresh_interval = "5m"
}

api_proxy {
  # The application sends no token; the proxy attaches its auto-auth token.
  use_auto_auth_token = true
}

listener "tcp" {
  address                = "127.0.0.1:8200"
  tls_disable            = true
  require_request_header = true
}
