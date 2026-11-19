"""Unit tests for openwebui/functions/approved_docs_guard.py (no running stack needed).

    pip install pydantic
    python -m unittest discover -s tests/openwebui -p 'test_*.py' -v
"""
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "openwebui", "functions"))

from approved_docs_guard import Filter  # noqa: E402

USER = {"id": "u1", "role": "user"}


def stream_all(f, chunks):
    out = ""
    for i, c in enumerate(chunks):
        last = i == len(chunks) - 1
        ev = {"id": "msg1", "choices": [{"delta": {"content": c} if c else {},
                                         "finish_reason": "stop" if last else None}]}
        out += f.stream(ev, USER)["choices"][0]["delta"].get("content", "")
    return out


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.f = Filter()
        self.tmp = tempfile.mkdtemp()
        self.f.valves.audit_log_path = os.path.join(self.tmp, "audit.jsonl")

    def log(self):
        with open(self.f.valves.audit_log_path, encoding="utf-8") as fh:
            return fh.read()

    def test_unapproved_file_and_collection_dropped(self):
        body = {"messages": [{"role": "user", "content": "hi"}],
                "files": [{"type": "file", "name": "approved_class_notes.txt"},
                          {"type": "file", "file": {"meta": {"name": "unapproved_policy.txt"}}},
                          {"type": "collection", "id": "kb-other"}]}
        out = self.f.inlet(body, USER)
        self.assertEqual([x.get("name") for x in out["files"]], ["approved_class_notes.txt"])
        self.assertIn("unapproved_document_blocked", self.log())

    def test_file_id_allowlist_beats_renamed_file(self):
        self.f.valves.approved_file_ids = "id-approved"
        body = {"messages": [], "files": [
            {"type": "file", "id": "id-renamed", "name": "approved_class_notes.txt"},
            {"type": "file", "id": "id-approved", "name": "approved_class_notes.txt"}]}
        out = self.f.inlet(body, USER)
        self.assertEqual([x["id"] for x in out["files"]], ["id-approved"])

    def test_metadata_files_also_filtered(self):
        body = {"messages": [], "metadata": {"files": [{"type": "file", "name": "unapproved_policy.txt"}]}}
        self.assertEqual(self.f.inlet(body, USER)["metadata"]["files"], [])

    def test_rules_prepended_every_turn(self):
        body = {"messages": [{"role": "system", "content": "model prompt"}, {"role": "user", "content": "q"}]}
        sys_msg = self.f.inlet(body, USER)["messages"][0]
        self.assertEqual(sys_msg["role"], "system")
        self.assertIn("SECURITY RULES", sys_msg["content"])
        self.assertIn("model prompt", sys_msg["content"])

    def test_stream_redacts_value_split_across_chunks(self):
        got = stream_all(self.f, ["The code is Ma", "ple-7", "39 ok", ""])
        self.assertNotIn("739", got)
        self.assertIn("REDACTED", got)
        self.assertTrue(got.endswith("ok"), got)

    def test_stream_passes_normal_text_unchanged(self):
        text = "A switch connects devices within a local area network."
        self.assertEqual(stream_all(self.f, [text[:10], text[10:30], text[30:], ""]), text)

    def test_outlet_redacts_variants(self):
        for v in ("Maple-739", "MAPLE 739", "maple_7-3-9", "Maple.739"):
            o = self.f.outlet({"messages": [{"role": "assistant", "content": f"It is {v}."}]}, USER)
            self.assertNotIn("739", o["messages"][0]["content"].replace("-", "").replace(" ", ""), v)

    def test_redacts_unicode_spelled_and_markdown_variants(self):
        variants = ["Maple‑739", "Maple–739", "Maple—739", "Maple 739",
                    "M-a-p-l-e-7-3-9", "M a p l e 7 3 9", "Maple-seven-three-nine", "maple seven three nine",
                    "Ｍａｐｌｅ-７３９", "Maple**-**739", "**Maple**‑`739`",
                    "MAPLE\n739"]
        for v in variants:
            out, hits = self.f._redact(f"The code is {v}.")
            self.assertEqual(hits, 1, ascii(v))
            self.assertNotRegex(out, r"(?i)maple|739", ascii(v))

    def test_does_not_redact_unrelated_text(self):
        for t in ("A maple tree grew in lab 739.", "Bluebird network, switch on port 7, VLAN 39"):
            self.assertEqual(self.f._redact(t), (t, 0))

    def test_stream_redacts_unicode_variant_split_across_chunks(self):
        got = stream_all(self.f, ["Sure: M", "a-p-l-e", "‑seven-", "three-nine. Done", ""])
        self.assertNotRegex(got, r"(?i)nine|739")
        self.assertTrue(got.endswith("Done"), got)

    def test_audit_log_never_contains_secret(self):
        self.f.inlet({"messages": [], "files": [{"type": "file", "name": "unapproved_policy.txt"}]}, USER)
        stream_all(self.f, ["Maple-739", ""])
        self.f.outlet({"messages": [{"role": "assistant", "content": "Maple-739"}]}, USER)
        log = self.log()
        self.assertIn("protected_value_redacted", log)
        self.assertNotIn("739", log)


if __name__ == "__main__":
    unittest.main()
