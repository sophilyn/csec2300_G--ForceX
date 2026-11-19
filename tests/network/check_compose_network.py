"""Static firewall rules for docker-compose.yml (Control 1). Runs in CI on every pull request.

Reads the resolved Compose config as JSON on stdin and fails if a change would weaken the
network segmentation:
    docker compose config --format json | python3 tests/network/check_compose_network.py
"""
import json
import sys

PUBLIC_SERVICE = "proxy"  # HTTPS reverse proxy (Control 6): the only service allowed to publish host ports
AGENT = "adk-agent"
# Services the public-facing proxy must never share a network with.
BACKEND_SERVICES = ("ollama", AGENT)


def problems(config: dict) -> list:
    services = config.get("services", {})
    networks = config.get("networks", {})
    found = []

    for name, svc in services.items():
        for port in svc.get("ports", []):
            if name != PUBLIC_SERVICE:
                found.append(f"{name} publishes a host port ({port.get('published')}); only {PUBLIC_SERVICE} may")
            elif port.get("host_ip") != "127.0.0.1":
                found.append(f"{name} port {port.get('published')} is not bound to 127.0.0.1 only")
        if not svc.get("networks"):
            found.append(f"{name} has no explicit network (would use the shared default network)")

    agent_nets = set(services.get(AGENT, {}).get("networks", {}))
    for net in agent_nets:
        if not networks.get(net, {}).get("internal"):
            found.append(f"{AGENT} is on network '{net}', which is not internal (would allow internet access)")
    # Open WebUI may call the agent's API, but only over internal network(s) that no other service joins.
    shared = agent_nets & set(services.get("open-webui", {}).get("networks", {}))
    for net in sorted(shared):
        if not networks.get(net, {}).get("internal"):
            found.append(f"{AGENT} and open-webui share network '{net}', which is not internal")
        others = sorted(n for n, svc in services.items()
                        if n not in (AGENT, "open-webui") and net in (svc.get("networks") or {}))
        if others:
            found.append(f"network '{net}' links {AGENT} and open-webui but also has {others}; "
                         f"it must contain only those two")

    proxy_nets = set(services.get(PUBLIC_SERVICE, {}).get("networks", {}))
    for backend in BACKEND_SERVICES:
        shared = proxy_nets & set(services.get(backend, {}).get("networks", {}))
        if shared:
            found.append(f"{PUBLIC_SERVICE} and {backend} share network(s) {sorted(shared)}; "
                         f"the proxy may reach open-webui only")
    return found


def main() -> int:
    found = problems(json.load(sys.stdin))
    for p in found:
        print(f"FAIL: {p}")
    if not found:
        print("PASS: only the HTTPS proxy is published (127.0.0.1); every service has an explicit network; "
              "the ADK agent is on internal networks only and shares only a private internal link with open-webui; "
              "the proxy shares no network with ollama or the agent")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
