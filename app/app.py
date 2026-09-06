#!/usr/bin/env python3
"""
Multi-tenant demo - the application calls Vault's API, and Vault Proxy caches it.

A request names a tenant, and only then does the application know which secret it
needs:  kv-demo/data/tenants/<tenant>/api-key.  That path cannot be rendered to a
file in advance, which is why this application calls the API rather than reading a
file like the AWS implementations do.

What it still does NOT do:
  - authenticate to Vault
  - hold, store or renew a Vault token
  - implement any caching

It sends an unauthenticated request to 127.0.0.1. Vault Proxy attaches its own
auto-auth token, serves repeated reads from its cache, and keeps that cache current
by subscribing to Vault's KV events.
"""
import datetime, json, os, threading, time, urllib.error, urllib.request

# The only configuration. Note the address: this is the local proxy, not Vault.
VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://127.0.0.1:8200")
VAULT_NAMESPACE = os.environ.get("VAULT_NAMESPACE", "")
KV_MOUNT = os.environ.get("KV_MOUNT", "kv-demo")
TENANTS = os.environ.get("TENANTS", "acme,globex,initech").split(",")

STATE = {
    "config": {
        "vault_addr": VAULT_ADDR, "kv_mount": KV_MOUNT,
        "namespace": VAULT_NAMESPACE or "(none)",
        "token_in_process": False,
        "host": os.environ.get("HOSTNAME", "?"),
    },
    "tenants": TENANTS,
    "last": None,
    "history": [],
    "baseline": {},   # first observed latency per tenant, for the cache verdict
}
LOCK = threading.Lock()


def mask(v):
    if not v:
        return ""
    return v[:7] + "•" * 8 + v[-4:] if len(v) > 14 else "•" * 8


def fetch(tenant):
    """One read of one tenant's secret, through the local proxy."""
    path = f"{KV_MOUNT}/data/tenants/{tenant}/api-key"
    url = f"{VAULT_ADDR}/v1/{path}"
    req = urllib.request.Request(url, method="GET")
    # Vault Proxy requires this header when require_request_header is on.
    req.add_header("X-Vault-Request", "true")
    if VAULT_NAMESPACE:
        req.add_header("X-Vault-Namespace", VAULT_NAMESPACE)
    # deliberately NO X-Vault-Token: the proxy supplies it

    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            body = json.load(r)
        ms = int((time.time() - t0) * 1000)
        data = body["data"]["data"]
        version = body["data"]["metadata"]["version"]
        ok, err = True, None
    except urllib.error.HTTPError as e:
        ms = int((time.time() - t0) * 1000)
        data, version, ok = {}, None, False
        err = f"HTTP {e.code}: {e.read().decode()[:160]}"
    except Exception as e:
        ms = int((time.time() - t0) * 1000)
        data, version, ok, err = {}, None, False, str(e)

    with LOCK:
        # Whether this was a cache hit is not guessed from latency - it is known.
        # The first read of a given path since the proxy started must reach Vault;
        # every later read of the same path is answered from the proxy's cache.
        base = STATE["baseline"].get(tenant)
        first_time = base is None
        if ok and first_time:
            STATE["baseline"][tenant] = ms
        served_locally = ok and not first_time
        entry = {
            "ts": datetime.datetime.now().strftime("%H:%M:%S"),
            "tenant": tenant, "path": path, "ms": ms, "ok": ok, "error": err,
            "cached": served_locally, "first_ms": STATE["baseline"].get(tenant),
            "version": version,
            "value_preview": mask(data.get("value")),
            "downstream": data.get("downstream"),
        }
        STATE["last"] = entry
        STATE["history"].insert(0, entry)
        del STATE["history"][40:]
    return entry


# --------------------------------------------------------------------------- HTTP
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        p = urlparse(self.path)
        if p.path in ("/", "/index.html"):
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if p.path == "/healthz":
            return self._send(200, "ok", "text/plain")
        if p.path == "/api/state":
            with LOCK:
                pub = dict(STATE)
                pub["now"] = time.time()
            return self._send(200, json.dumps(pub))
        return self._send(404, "{}")

    def do_POST(self):
        p = urlparse(self.path)
        if p.path == "/api/fetch":
            tenant = (parse_qs(p.query).get("tenant") or [""])[0]
            if tenant not in TENANTS:
                return self._send(400, json.dumps({"error": "unknown tenant"}))
            return self._send(200, json.dumps(fetch(tenant)))
        if p.path == "/api/reset":
            with LOCK:
                STATE["history"].clear()
                STATE["baseline"].clear()
                STATE["last"] = None
            return self._send(200, json.dumps({"ok": True}))
        return self._send(404, "{}")


PAGE = r"""<!doctype html><html><head><meta charset="utf-8">
<title>Vault Proxy - KV secret caching</title>
<style>
*{box-sizing:border-box}
body{margin:0;background:#fbfaf8;color:#1c1a17;font:14px/1.6 ui-sans-serif,-apple-system,"Segoe UI",sans-serif}
.mono,code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
header{padding:18px 24px;border-bottom:1px solid #e6e1d8}
h1{font-size:16px;margin:0 0 3px;font-weight:650;letter-spacing:-.01em}
.sub{color:#7a7266;font-size:12.5px;margin:0}
.wrap{max-width:940px;margin:0 auto;padding:20px 24px 60px;display:flex;flex-direction:column;gap:18px}
.card{background:#fff;border:1px solid #e6e1d8;border-radius:10px;padding:18px 20px}
.card h2{margin:0 0 4px;font-size:14px;font-weight:650}
.card p.why{color:#7a7266;font-size:12.5px;margin:0 0 14px;max-width:70ch}
.knows{display:grid;grid-template-columns:150px 1fr;gap:5px 14px;font-size:12.5px}
.knows div:nth-child(odd){color:#7a7266}
.row{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:4px}
button{background:#1c1a17;color:#fbfaf8;border:0;border-radius:7px;padding:9px 16px;font-size:13px;cursor:pointer;font-weight:500}
button:hover{background:#3a352e}
button.ghost{background:#fff;color:#1c1a17;border:1px solid #d8d1c5}
button.ghost:hover{background:#f4f1ea}
.result{margin-top:14px;border:1px solid #e6e1d8;border-radius:8px;padding:14px 16px;background:#fdfcfa}
.result.miss{border-left:3px solid #b8860b}
.result.hit{border-left:3px solid #2f6d3d}
.big{font-size:26px;font-weight:650;letter-spacing:-.02em}
.badge{display:inline-block;font-size:11px;padding:3px 9px;border-radius:20px;margin-left:9px;vertical-align:3px}
.badge.hit{background:#eaf5ec;color:#2f6d3d;border:1px solid #bcdcc4}
.badge.miss{background:#fdf4e3;color:#8a6d00;border:1px solid #e8d99a}
.kv{display:grid;grid-template-columns:130px 1fr;gap:5px 14px;font-size:12.5px;margin-top:12px}
.kv div:nth-child(odd){color:#7a7266}
table{width:100%;border-collapse:collapse;font-size:12px;margin-top:6px}
th{text-align:left;color:#7a7266;font-weight:500;padding:6px;border-bottom:1px solid #e6e1d8}
td{padding:6px;border-bottom:1px solid #f0ece4}
td.n{text-align:right;font-variant-numeric:tabular-nums}
.note{font-size:12px;color:#7a7266;border-left:3px solid #e6e1d8;padding-left:12px;margin-top:14px;line-height:1.6}
.err{color:#a32b22;font-size:12.5px}
</style></head><body>
<header>
  <h1>Multi-tenant service &middot; Vault Proxy KV caching</h1>
  <p class="sub">The tenant is chosen at request time, so the secret path cannot be rendered to a file in advance.</p>
</header>

<div class="wrap">

  <div class="card">
    <h2>What this application knows about Vault</h2>
    <p class="why">It knows one address and one path shape. It has no token, no login code and no cache of its own.</p>
    <div class="knows">
      <div>Vault address</div><div class="mono" id="c-addr">-</div>
      <div>Namespace</div><div class="mono" id="c-ns">-</div>
      <div>Token in this process</div><div class="mono" id="c-tok">-</div>
      <div>Path it requests</div><div class="mono" id="c-path">-</div>
    </div>
  </div>

  <div class="card">
    <h2>Serve a tenant</h2>
    <p class="why">Click a tenant once — the proxy has to ask Vault. Click the same tenant again — the proxy answers from its own cache and Vault is not contacted.</p>
    <div class="row" id="tenants"></div>
    <div class="row"><button class="ghost" onclick="reset()">Clear history</button></div>
    <div id="result"></div>
  </div>

  <div class="card">
    <h2>Every request so far</h2>
    <table>
      <thead><tr><th>time</th><th>tenant</th><th>where it was served from</th><th class="n">latency</th></tr></thead>
      <tbody id="hist"><tr><td colspan="4" style="color:#a49a8c">no requests yet</td></tr></tbody>
    </table>
    <p class="note">Latency is the whole story. The first read of a tenant travels to Vault; later reads are
       answered on the loopback interface. Vault Proxy keeps the cached copy honest by subscribing to Vault's
       event feed, so editing the secret in Vault refreshes it here — no polling, and no stale value.</p>
  </div>
</div>

<script>
const $=i=>document.getElementById(i);
let S={};
const esc=s=>(s==null?'':String(s)).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));

function render(){
  const c=S.config||{};
  $('c-addr').textContent=c.vault_addr||'-';
  $('c-ns').textContent=c.namespace||'-';
  $('c-tok').textContent=c.token_in_process?'yes':'none';
  $('c-path').textContent=(c.kv_mount||'kv')+'/data/tenants/<tenant>/api-key';

  $('tenants').innerHTML=(S.tenants||[]).map(t=>
    `<button onclick="go('${esc(t)}')">Serve ${esc(t)}</button>`).join('');

  const r=S.last;
  if(!r){ $('result').innerHTML=''; }
  else if(!r.ok){
    $('result').innerHTML=`<div class="result miss"><div class="err">${esc(r.error)}</div></div>`;
  } else {
    $('result').innerHTML=
      `<div class="result ${r.cached?'hit':'miss'}">
         <span class="big">${r.ms} ms</span>
         <span class="badge ${r.cached?'hit':'miss'}">${r.cached?'served by the proxy cache':'fetched from Vault'}</span>
         <div class="kv">
           <div>tenant</div><div class="mono">${esc(r.tenant)}</div>
           <div>path requested</div><div class="mono">${esc(r.path)}</div>
           <div>api key</div><div class="mono">${esc(r.value_preview)}</div>
           <div>downstream</div><div class="mono">${esc(r.downstream)}</div>
           <div>kv version</div><div class="mono">${esc(r.version)}</div>
           <div>first read of this tenant</div><div class="mono">${esc(r.first_ms)} ms &nbsp;(reached Vault)</div>
         </div>
       </div>`;
  }

  const h=S.history||[];
  $('hist').innerHTML = h.length ? h.map(e=>
    `<tr><td class="mono">${esc(e.ts)}</td><td>${esc(e.tenant)}</td>
     <td>${e.ok?(e.cached?'proxy cache':'Vault'):'<span class="err">error</span>'}</td>
     <td class="n mono">${e.ms} ms</td></tr>`).join('')
    : '<tr><td colspan="4" style="color:#a49a8c">no requests yet</td></tr>';
}

async function load(){ try{ S=await (await fetch('/api/state')).json(); render(); }catch(e){} }
async function go(t){ await fetch('/api/fetch?tenant='+encodeURIComponent(t),{method:'POST'}); load(); }
async function reset(){ await fetch('/api/reset',{method:'POST'}); load(); }
load(); setInterval(load,3000);
</script>
</body></html>"""


if __name__ == "__main__":
    ThreadingHTTPServer(("", 8090), Handler).serve_forever()
