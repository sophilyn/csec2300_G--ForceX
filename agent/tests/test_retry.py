"""Unit tests for printed-tool-call detection (no ADK needed)."""
import sys
import unittest
from pathlib import Path

for _candidate in (Path(__file__).resolve().parents[1] / "gforcex_agent",
                   Path(__file__).resolve().parents[1] / "agents" / "gforcex_agent"):
    if (_candidate / "retry.py").is_file():
        sys.path.insert(0, str(_candidate))
        break
from retry import looks_like_printed_tool_call  # noqa: E402


class RetryDetection(unittest.TestCase):
    def test_detects_observed_failure(self):
        # Exact (malformed) text recorded from llama3.2:3b on 2026-11-10.
        self.assertTrue(looks_like_printed_tool_call('{"name":"get_approved_documents","parameters:{}}', []))

    def test_detects_wellformed_variant(self):
        self.assertTrue(looks_like_printed_tool_call(' {"name": "get_approved_documents", "parameters": {}}\n', []))

    def test_ignores_real_answers(self):
        self.assertFalse(looks_like_printed_tool_call("The fictional lab network is named Bluebird.", []))
        self.assertFalse(looks_like_printed_tool_call("I cannot find that in the approved documents.", []))

    def test_ignores_when_tool_actually_ran(self):
        self.assertFalse(looks_like_printed_tool_call('{"name":"get_approved_documents"}', ["get_approved_documents"]))

    def test_ignores_empty(self):
        self.assertFalse(looks_like_printed_tool_call("", []))


if __name__ == "__main__":
    unittest.main()
