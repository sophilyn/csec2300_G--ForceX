"""Unit tests for the static Compose firewall rules (no Docker needed)."""
import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_compose_network import problems  # noqa: E402

GOOD = {
    "services": {
        "ollama": {"networks": {"webui_net": None, "agent_net": None}},
        "open-webui": {"networks": {"webui_net": None},
                       "ports": [{"target": 8080, "published": "3000", "host_ip": "127.0.0.1"}]},
        "adk-agent": {"networks": {"agent_net": None}},
    },
    "networks": {"webui_net": {}, "agent_net": {"internal": True}},
}


class ComposeNetworkRules(unittest.TestCase):
    def check(self, mutate, expected_fragment):
        cfg = copy.deepcopy(GOOD)
        mutate(cfg)
        found = problems(cfg)
        self.assertTrue(any(expected_fragment in p for p in found), found)

    def test_good_config_passes(self):
        self.assertEqual(problems(GOOD), [])

    def test_agent_port_fails(self):
        self.check(lambda c: c["services"]["adk-agent"].update(ports=[{"published": "8000", "host_ip": "127.0.0.1"}]),
                   "adk-agent publishes a host port")

    def test_ollama_port_fails(self):
        self.check(lambda c: c["services"]["ollama"].update(ports=[{"published": "11434", "host_ip": "127.0.0.1"}]),
                   "ollama publishes a host port")

    def test_webui_on_all_interfaces_fails(self):
        self.check(lambda c: c["services"]["open-webui"]["ports"][0].update(host_ip=""), "not bound to 127.0.0.1")

    def test_agent_internet_access_fails(self):
        self.check(lambda c: c["networks"]["agent_net"].pop("internal"), "not internal")

    def test_agent_and_webui_sharing_a_network_fails(self):
        self.check(lambda c: c["services"]["open-webui"]["networks"].update(agent_net=None), "must be separated")

    def test_service_on_default_network_fails(self):
        self.check(lambda c: c["services"]["ollama"].pop("networks"), "no explicit network")


if __name__ == "__main__":
    unittest.main()
