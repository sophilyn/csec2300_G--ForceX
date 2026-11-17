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
check open    "Browser on this computer -> Open WebUI (127.0.0.1:3000)" "$(from_host 127.0.0.1 3000)"
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
check blocked "Open WebUI published on any address but 127.0.0.1" \
  "$(host_binds open-webui | grep -qv '^127\.0\.0\.1:' && echo "open (non-localhost bind)" || echo "blocked (localhost only)")"
lan_ip=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
if [[ -n "${lan_ip:-}" ]]; then
  check blocked "Other devices on the network -> Open WebUI (LAN IP:3000)" "$(from_host "$lan_ip" 3000)"
else
  echo "SKIP  no LAN IP found; cannot test access from other devices"
fi
check blocked "ADK agent -> Open WebUI (open-webui:8080)"                "$(from_container adk-agent open-webui 8080)"
check blocked "Open WebUI -> ADK agent (adk-agent:8000)"                 "$(from_container open-webui adk-agent 8000)"
check blocked "ADK agent -> internet (1.1.1.1:443)"                      "$(from_container adk-agent 1.1.1.1 443)"

echo "== Result: $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
