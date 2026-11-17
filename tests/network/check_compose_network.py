"""Static firewall rules for docker-compose.yml (Control 1). Runs in CI on every pull request.

Reads the resolved Compose config as JSON on stdin and fails if a change would weaken the
network segmentation:
    docker compose config --format json | python3 tests/network/check_compose_network.py
"""
import json
import sys

PUBLIC_SERVICE = "open-webui"  # the only service allowed to publish a port to the host
AGENT = "adk-agent"


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
    shared = agent_nets & set(services.get(PUBLIC_SERVICE, {}).get("networks", {}))
    if shared:
        found.append(f"{AGENT} and {PUBLIC_SERVICE} share network(s) {sorted(shared)}; they must be separated")
    return found


def main() -> int:
    found = problems(json.load(sys.stdin))
    for p in found:
        print(f"FAIL: {p}")
    if not found:
        print("PASS: only open-webui is published (127.0.0.1); every service has an explicit network; "
              "the ADK agent is on internal networks only and shares none with open-webui")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
