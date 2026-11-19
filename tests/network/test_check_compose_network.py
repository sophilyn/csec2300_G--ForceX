"""Unit tests for the static Compose firewall rules (no Docker needed)."""
import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_compose_network import problems  # noqa: E402

GOOD = {
    "services": {
        "proxy": {"networks": {"edge_net": None},
                  "ports": [{"target": 8443, "published": "3443", "host_ip": "127.0.0.1"},
                            {"target": 8080, "published": "3000", "host_ip": "127.0.0.1"}]},
        "ollama": {"networks": {"webui_net": None, "agent_net": None}},
        "open-webui": {"networks": {"webui_net": None, "edge_net": None, "agent_api_net": None}},
        "adk-agent": {"networks": {"agent_net": None, "agent_api_net": None}},
    },
    "networks": {"edge_net": {}, "webui_net": {}, "agent_net": {"internal": True},
                 "agent_api_net": {"internal": True}},
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

    def test_proxy_on_all_interfaces_fails(self):
        self.check(lambda c: c["services"]["proxy"]["ports"][0].update(host_ip=""), "not bound to 127.0.0.1")

    def test_webui_publishing_plain_http_port_fails(self):
        # Control 6: Open WebUI must be reached only through the HTTPS proxy.
        self.check(lambda c: c["services"]["open-webui"].update(ports=[{"published": "3000", "host_ip": "127.0.0.1"}]),
                   "open-webui publishes a host port")

    def test_proxy_reaching_ollama_fails(self):
        self.check(lambda c: c["services"]["proxy"]["networks"].update(webui_net=None), "proxy and ollama share")

    def test_proxy_reaching_agent_fails(self):
        self.check(lambda c: c["services"]["proxy"]["networks"].update(agent_net=None), "proxy and adk-agent share")

    def test_agent_internet_access_fails(self):
        self.check(lambda c: c["networks"]["agent_net"].pop("internal"), "not internal")

    def test_agent_and_webui_sharing_a_non_internal_network_fails(self):
        self.check(lambda c: c["networks"]["agent_api_net"].pop("internal"), "which is not internal")

    def test_webui_joining_the_agents_model_network_fails(self):
        # agent_net also has Ollama, so Open WebUI joining it breaks the "only those two" rule.
        self.check(lambda c: c["services"]["open-webui"]["networks"].update(agent_net=None), "must contain only those two")

    def test_proxy_joining_the_agent_api_link_fails(self):
        self.check(lambda c: c["services"]["proxy"]["networks"].update(agent_api_net=None), "must contain only those two")

    def test_service_on_default_network_fails(self):
        self.check(lambda c: c["services"]["ollama"].pop("networks"), "no explicit network")


if __name__ == "__main__":
    unittest.main()
