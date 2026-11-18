"""Unit tests for the audit log and audit report (no ADK, Ollama or Docker needed)."""
import io
import json
import logging
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

for _candidate in (Path(__file__).resolve().parents[1] / "gforcex_agent",
                   Path(__file__).resolve().parents[1] / "agents" / "gforcex_agent"):
    if (_candidate / "audit.py").is_file():
        sys.path.insert(0, str(_candidate))
        break
import audit  # noqa: E402
import audit_report  # noqa: E402
import tools  # noqa: E402


class AuditLogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "audit.jsonl"
        self._old = os.environ.get("AUDIT_LOG_PATH")
        os.environ["AUDIT_LOG_PATH"] = str(self.path)
        self._reset_logger()

    def tearDown(self):
        self._reset_logger()
        if self._old is None:
            os.environ.pop("AUDIT_LOG_PATH", None)
        else:
            os.environ["AUDIT_LOG_PATH"] = self._old
        self.tmp.cleanup()

    @staticmethod
    def _reset_logger():
        logger = logging.getLogger("gforcex.audit")
        for handler in list(logger.handlers):
            handler.close()
            logger.removeHandler(handler)

    def records(self):
        return [json.loads(line) for line in self.path.read_text().splitlines()]

    def log(self, event, **fields):
        with redirect_stderr(io.StringIO()):
            return audit.audit(event, **fields)

    def test_writes_one_json_object_per_event(self):
        self.log("query_received", question="What is the lab network named?")
        self.log("query_completed", answer_chars=42)
        recs = self.records()
        self.assertEqual([r["event"] for r in recs], ["query_received", "query_completed"])
        self.assertTrue(all(r["ts"].endswith("+00:00") for r in recs))  # UTC timestamps

    def test_question_text_is_kept(self):
        self.log("query_received", question="What is the lab network named?")
        self.assertEqual(self.records()[0]["question"], "What is the lab network named?")

    def test_secrets_in_text_are_redacted(self):
        question = ("my password=Hunter2-test and api_key: sk-abcdefghijklmnop1234 token is ghp_"
                    + "a" * 36 + " key " + "0123456789abcdef" * 4 + " AKIAABCDEFGHIJKLMNOP")
        self.log("query_received", question=question)
        logged = self.records()[0]["question"]
        for secret in ("Hunter2-test", "sk-abcdefghijklmnop1234", "ghp_" + "a" * 36,
                       "0123456789abcdef" * 4, "AKIAABCDEFGHIJKLMNOP"):
            self.assertNotIn(secret, logged)
        self.assertIn("password=[REDACTED]", logged)  # label kept so reviewers know what was hidden

    def test_newlines_cannot_forge_extra_log_entries(self):
        self.log("query_received", question='hi\n{"event": "admin_login", "ts": "x"}')
        self.assertEqual(len(self.path.read_text().splitlines()), 1)
        self.assertEqual(self.records()[0]["event"], "query_received")

    def test_long_text_is_truncated(self):
        self.log("query_received", question="x" * 2000)
        self.assertLess(len(self.records()[0]["question"]), 600)
        self.assertIn("[truncated", self.records()[0]["question"])

    def test_document_tools_audit_names_never_contents(self):
        docs = Path(self.tmp.name) / "approved"
        docs.mkdir()
        (docs / "notes.txt").write_text("The secret lab code is Kite-55.")
        old = os.environ.get("APPROVED_DOCS_DIR")
        os.environ["APPROVED_DOCS_DIR"] = str(docs)
        try:
            with redirect_stderr(io.StringIO()):
                tools.read_approved_document("notes.txt")
                tools.read_approved_document("../etc/passwd")
        finally:
            if old is None:
                os.environ.pop("APPROVED_DOCS_DIR", None)
            else:
                os.environ["APPROVED_DOCS_DIR"] = old
        recs = self.records()
        self.assertEqual([r["event"] for r in recs], ["document_served", "access_refused"])
        self.assertEqual(recs[0]["name"], "notes.txt")
        self.assertIn("../etc/passwd", recs[1]["name"])
        self.assertNotIn("Kite-55", self.path.read_text())

    def test_events_inside_a_query_carry_its_query_id(self):
        token = audit.set_query_id("abc123def456")
        try:
            self.log("document_served", name="notes.txt", bytes=10)
            self.log("query_completed", query_id="explicit-id")  # an explicit id is never overwritten
        finally:
            audit.reset_query_id(token)
        self.log("access_refused", name="'x'")  # outside the query: no id
        recs = self.records()
        self.assertEqual(recs[0]["query_id"], "abc123def456")
        self.assertEqual(recs[1]["query_id"], "explicit-id")
        self.assertNotIn("query_id", recs[2])

    def test_missing_log_folder_falls_back_to_stderr(self):
        os.environ["AUDIT_LOG_PATH"] = str(Path(self.tmp.name) / "missing" / "audit.jsonl")
        self._reset_logger()
        err = io.StringIO()
        with redirect_stderr(err):
            audit.audit("query_received", question="hi")
        self.assertIn("audit_file_unavailable", err.getvalue())
        self.assertIn('"event": "query_received"', err.getvalue())


class AuditReportTests(unittest.TestCase):
    @staticmethod
    def line(event, ts="2026-11-17T20:00:00.000+00:00", **kw):
        return json.dumps({"ts": ts, "event": event, **kw})

    def test_counts_events_and_no_alert_for_normal_use(self):
        report = audit_report.summarize([self.line("query_received"), self.line("document_served"),
                                         self.line("access_refused", name="'x'")])
        self.assertEqual(report["events"]["query_received"], 1)
        self.assertEqual(report["alerts"], [])

    def test_alerts_on_repeated_refusals(self):
        lines = [self.line("access_refused", name=f"'../{i}'") for i in range(3)]
        self.assertTrue(any("refused document requests" in a for a in audit_report.summarize(lines)["alerts"]))

    def test_alerts_on_failed_queries_and_tampered_lines(self):
        alerts = audit_report.summarize([self.line("query_failed", error="ReadTimeout"), "not json"])["alerts"]
        self.assertTrue(any("failed queries" in a for a in alerts))
        self.assertTrue(any("not valid JSON" in a for a in alerts))

    def test_since_filter(self):
        lines = [self.line("access_refused", ts="2026-11-17T19:00:00"),
                 self.line("access_refused", ts="2026-11-17T21:00:00")]
        self.assertEqual(audit_report.summarize(lines, since="2026-11-17T20:00")["events"],
                         {"access_refused": 1})


class WebuiReportTests(unittest.TestCase):
    @staticmethod
    def req(path, status, method="POST"):
        # Format copied from a real Open WebUI v0.12.5 log line.
        return (f'2026-11-18 01:59:51.028 | INFO     | uvicorn.protocols.http.httptools_impl:send:482 - '
                f'172.19.0.1:0 - "{method} {path} HTTP/1.1" {status}')

    def test_counts_signins_and_denied_requests(self):
        lines = [self.req("/api/v1/auths/signin", 200), self.req("/api/v1/auths/signin", 400),
                 self.req("/api/v1/chats/", 401, "GET"), self.req("/api/v1/chats/", 200, "GET"),
                 "2026-11-18 01:59:50.809 | INFO | open_webui.models.auths:authenticate_user:336 - x"]
        report = audit_report.summarize_webui(lines)
        self.assertEqual(report["events"], {"signin_succeeded": 1, "signin_failed": 1, "request_denied": 1})
        self.assertEqual(report["alerts"], [])

    def test_alerts_on_repeated_failed_signins(self):
        lines = [self.req("/api/v1/auths/signin", 400) for _ in range(audit_report.SIGNIN_FAILURE_ALERT_THRESHOLD)]
        alerts = audit_report.summarize_webui(lines)["alerts"]
        self.assertTrue(any("possible password guessing" in a for a in alerts))

    def test_ignores_unrelated_lines(self):
        self.assertEqual(audit_report.summarize_webui(["", "random text", '"GET / HTTP/1.1" 200'])["events"], {})


if __name__ == "__main__":
    unittest.main()
