#!/usr/bin/env bash
# Network firewall test for the G-ForceX stack (Control 1: Firewall Configuration).
#
# Checks that every connection the app needs works, and that every other
# connection is blocked. Run from the repository root with the stack running:
#     bash tests/network/check_network.sh
# Exit code 0 = every check matched its expected result.
#
# Each probe only opens (and immediately closes) a TCP connection. No data is sent.
set -u

PROBE='import socket,sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=4).close(); print("open")
except Exception as e:
    print("blocked (" + type(e).__name__ + ")")'

pass=0; fail=0

check() {  # check <expected open|blocked> <description> <result>
  local expected="$1" desc="$2" result="$3" status
  if [[ "$result" == "$expected"* ]]; then status="PASS"; pass=$((pass + 1)); else status="FAIL"; fail=$((fail + 1)); fi
  printf '%-4s  expected %-7s got %-28s  %s\n' "$status" "$expected" "$result" "$desc"
}

from_host()      { python3 -c "$PROBE" "$1" "$2"; }
from_container() { docker compose exec -T "$1" python3 -c "$PROBE" "$2" "$3" 2>/dev/null || echo "blocked (exec failed)"; }

echo "== Allowed connections (the app needs these) =="
check open    "Browser on this computer -> HTTPS proxy (127.0.0.1:3443)" "$(from_host 127.0.0.1 3443)"
check open    "Browser on this computer -> HTTP redirect (127.0.0.1:3000)" "$(from_host 127.0.0.1 3000)"
check open    "Open WebUI -> Ollama (ollama:11434)"                      "$(from_container open-webui ollama 11434)"
check open    "ADK agent -> Ollama (ollama:11434)"                       "$(from_container adk-agent ollama 11434)"

echo "== Blocked connections (nothing should need these) =="
# Ask Docker what each container publishes, instead of probing the port: another program on
# this computer (for example the Ollama desktop app) may use the same port number.
host_binds() {  # host_binds <service> -> "IP:port" lines for every published port of that container
  docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}:{{.HostPort}}{{"\n"}}{{end}}{{end}}' \
    "$(docker compose ps -q "$1" 2>/dev/null)" 2>/dev/null | grep -v '^$'
}
published() { [[ -n "$(host_binds "$1")" ]] && echo "open (published: $(host_binds "$1" | tr '\n' ' '))" || echo "blocked (not published)"; }
check blocked "This computer -> Ollama container (any port)"            "$(published ollama)"
check blocked "This computer -> ADK agent container (any port)"         "$(published adk-agent)"
check blocked "This computer -> Open WebUI plain HTTP (no proxy)"      "$(published open-webui)"
check blocked "HTTPS proxy published on any address but 127.0.0.1" \
  "$(host_binds proxy | grep -qv '^127\.0\.0\.1:' && echo "open (non-localhost bind)" || echo "blocked (localhost only)")"
# Find this computer's LAN IPv4 address on macOS, Linux and Windows (Git Bash). A UDP "connect" only
# picks the outgoing interface; no packet is sent. Anything that is not an IPv4 address is ignored, so a
# broken lookup is reported as SKIP instead of a false PASS.
lan_ip=$(python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("192.0.2.1", 9)); print(s.getsockname()[0])' 2>/dev/null | tr -d '\r')
[[ "$lan_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$lan_ip" != 127.* ]] || lan_ip=""
if [[ -n "${lan_ip:-}" ]]; then
  check blocked "Other devices on the network -> HTTPS proxy (LAN IP:3443)" "$(from_host "$lan_ip" 3443)"
  check blocked "Other devices on the network -> HTTP redirect (LAN IP:3000)" "$(from_host "$lan_ip" 3000)"
else
  echo "SKIP  no LAN IP found; cannot test access from other devices"
fi
check blocked "ADK agent -> Open WebUI (open-webui:8080)"                "$(from_container adk-agent open-webui 8080)"
check blocked "Open WebUI -> ADK agent (adk-agent:8000)"                 "$(from_container open-webui adk-agent 8000)"
check blocked "ADK agent -> internet (1.1.1.1:443)"                      "$(from_container adk-agent 1.1.1.1 443)"

echo "== Result: $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
