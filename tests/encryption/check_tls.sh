#!/usr/bin/env bash
# Encryption test for the G-ForceX stack (Control 6: Data Encryption).
#
# Checks that browser traffic to Open WebUI is encrypted with TLS, that plain HTTP only redirects,
# and that the secret key is handled safely. Run from the repository root with the stack running:
#     bash tests/encryption/check_tls.sh
# Exit code 0 = every check passed. Nothing secret is printed.
set -u

pass=0; fail=0
check() {  # check <PASS|FAIL> <description>
  if [[ "$1" == PASS ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
  printf '%-4s  %s\n' "$1" "$2"
}
ok() { if "$@" >/dev/null 2>&1; then echo PASS; else echo FAIL; fi; }

# Caddy's local root certificate (public part only), so the client can verify the server certificate.
tmp=$(mktemp -d); trap 'rm -f "$tmp/root.crt"; rmdir "$tmp"' EXIT
docker compose cp proxy:/data/caddy/pki/authorities/local/root.crt "$tmp/root.crt" >/dev/null 2>&1

echo "== Encryption in transit (browser <-> Open WebUI) =="
python3 - "$tmp/root.crt" <<'EOF'
import http.client, socket, ssl, sys

cafile = sys.argv[1]
results = []
def report(ok, text):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + text)

try:
    ctx = ssl.create_default_context(cafile=cafile)
except Exception as exc:
    report(False, f"could not load the proxy's root certificate ({type(exc).__name__}); is the stack running?")
    sys.exit(1)

for host in ("localhost", "127.0.0.1"):
    try:
        with socket.create_connection((host, 3443), timeout=5) as raw, ctx.wrap_socket(raw, server_hostname=host) as tls:
            version = tls.version()
            report(version in ("TLSv1.3", "TLSv1.2"),
                   f"https://{host}:3443 uses {version} ({tls.cipher()[0]}), certificate verified for {host}")
    except Exception as exc:
        report(False, f"https://{host}:3443 TLS handshake or certificate check failed ({type(exc).__name__}: {exc})")

try:
    conn = http.client.HTTPSConnection("localhost", 3443, context=ctx, timeout=10)
    conn.request("GET", "/health")
    resp = conn.getresponse(); body = resp.read().decode(errors="replace")
    report(resp.status == 200, f"Open WebUI answers through the HTTPS proxy (/health -> {resp.status} {body.strip()[:40]})")
    hsts = resp.getheader("Strict-Transport-Security")
    report(bool(hsts), f"HSTS header tells the browser to use HTTPS only ({hsts})")
except Exception as exc:
    report(False, f"HTTPS request to Open WebUI failed ({type(exc).__name__}: {exc})")

try:
    conn = http.client.HTTPConnection("localhost", 3000, timeout=5)
    conn.request("GET", "/some/page")
    resp = conn.getresponse(); resp.read()
    loc = resp.getheader("Location") or ""
    report(resp.status in (301, 308) and loc.startswith("https://"),
           f"http://localhost:3000 only redirects to HTTPS ({resp.status} -> {loc})")
except Exception as exc:
    report(False, f"HTTP redirect check failed ({type(exc).__name__}: {exc})")

try:
    with socket.create_connection(("localhost", 3443), timeout=5) as raw:
        raw.sendall(b"GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        data = raw.recv(4096)
    report(b'"status":true' not in data, "plain HTTP sent to the HTTPS port does not reach Open WebUI")
except OSError:
    report(True, "plain HTTP sent to the HTTPS port does not reach Open WebUI (connection closed)")

sys.exit(min(results.count(False), 1))
EOF
[[ $? -eq 0 ]] || fail=$((fail + 1))

host_binds=$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}} {{end}}{{end}}' \
  "$(docker compose ps -q open-webui 2>/dev/null)" 2>/dev/null)
[[ -z "${host_binds// /}" ]] && check PASS "Open WebUI publishes no plain-HTTP port of its own" \
                             || check FAIL "Open WebUI publishes host port(s) $host_binds, bypassing TLS"

echo "== Secrets and keys =="
# Compose must refuse to start without the key (an empty key would be silently replaced).
if env -u WEBUI_SECRET_KEY docker compose --env-file /dev/null config --quiet >/dev/null 2>&1; then
  check FAIL "docker compose starts without WEBUI_SECRET_KEY"
else
  check PASS "docker compose refuses to start without WEBUI_SECRET_KEY"
fi
check "$(ok docker compose exec -T open-webui sh -c 'test ${#WEBUI_SECRET_KEY} -ge 32')" \
  "Open WebUI's secret key is set and at least 32 characters (value not printed)"
check "$(if git ls-files --error-unmatch .env >/dev/null 2>&1; then echo FAIL; else echo PASS; fi)" \
  ".env is not tracked by Git"
check "$(if git ls-files | grep -qiE '\.(key|pem)$|(^|/)root\.crt$'; then echo FAIL; else echo PASS; fi)" \
  "no private keys or certificates are committed (the proxy's keys live in the caddy_data volume)"

if [[ $fail -eq 0 ]]; then echo "== Result: all checks passed =="; else echo "== Result: FAILED (see FAIL lines above) =="; fi
[[ $fail -eq 0 ]]
