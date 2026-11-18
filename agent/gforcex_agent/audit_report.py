"""Summarizes the audit log and flags suspicious activity (Control 2, detective part).

Usage (inside the agent container):
    python -m gforcex_agent.audit_report            # whole current log
    python -m gforcex_agent.audit_report --since 2026-11-17T20:00:00
    # also review Open WebUI's sign-ins (its log is piped in from the host):
    docker compose logs --no-log-prefix open-webui |
        docker compose exec -T adk-agent python -m gforcex_agent.audit_report --webui-log -
Exit code 2 when an alert is raised, so the report can be used in scripts.
tests/logging/review_logs.sh runs the combined review for both logs.
"""
import argparse
import collections
import json
import os
import re
import sys

REFUSAL_ALERT_THRESHOLD = 3  # refused document requests in one log window
SIGNIN_FAILURE_ALERT_THRESHOLD = 5  # failed Open WebUI sign-ins in one log window (password guessing)

# Open WebUI's request log line, for example:
#   2026-11-18 01:59:51.028 | INFO | uvicorn...:send:482 - 172.19.0.1:0 - "POST /api/v1/auths/signin HTTP/1.1" 400
_WEBUI_REQUEST_RE = re.compile(r'^(?P<ts>\d{4}-\d{2}-\d{2} [\d:.]+).*"(?P<method>[A-Z]+) (?P<path>\S+) HTTP/[\d.]+" (?P<status>\d{3})')
_SIGNIN_PATH = "/api/v1/auths/signin"


def summarize(lines, since: str = "") -> dict:
    counts, refusals, errors, bad_lines = collections.Counter(), [], [], 0
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            bad_lines += 1
            continue
        if since and rec.get("ts", "") < since:
            continue
        counts[rec.get("event", "?")] += 1
        if rec.get("event") == "access_refused":
            refusals.append(rec)
        if rec.get("event") in ("query_failed", "audit_file_unavailable"):
            errors.append(rec)
    alerts = []
    if len(refusals) >= REFUSAL_ALERT_THRESHOLD:
        alerts.append(f"{len(refusals)} refused document requests (threshold {REFUSAL_ALERT_THRESHOLD}): "
                      "possible attempt to read unapproved files")
    if errors:
        alerts.append(f"{len(errors)} failed queries or audit errors")
    if bad_lines:
        alerts.append(f"{bad_lines} log lines are not valid JSON: possible tampering or corruption")
    return {"events": dict(counts), "refusals": refusals, "alerts": alerts}


def summarize_webui(lines) -> dict:
    """Counts Open WebUI sign-ins and denied API requests from its request log lines."""
    counts = collections.Counter()
    failures = []
    for line in lines:
        m = _WEBUI_REQUEST_RE.search(line)
        if not m:
            continue
        status, path = int(m["status"]), m["path"].split("?")[0]
        if path == _SIGNIN_PATH and m["method"] == "POST":
            if status == 200:
                counts["signin_succeeded"] += 1
            elif 400 <= status < 500:
                counts["signin_failed"] += 1
                failures.append({"ts": m["ts"], "status": status})
        elif status in (401, 403):
            counts["request_denied"] += 1
    alerts = []
    if counts["signin_failed"] >= SIGNIN_FAILURE_ALERT_THRESHOLD:
        alerts.append(f"{counts['signin_failed']} failed Open WebUI sign-ins "
                      f"(threshold {SIGNIN_FAILURE_ALERT_THRESHOLD}): possible password guessing")
    return {"events": dict(counts), "signin_failures": failures, "alerts": alerts}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", default=os.environ.get("AUDIT_LOG_PATH", "/var/log/gforcex/audit.jsonl"))
    parser.add_argument("--since", default="", help="ISO time; only count events at or after it")
    parser.add_argument("--webui-log", default="",
                        help="Open WebUI log file to review too, or - for standard input")
    args = parser.parse_args()
    try:
        with open(args.file, encoding="utf-8") as fh:
            report = summarize(fh, args.since)
    except FileNotFoundError:
        print(f"No audit log at {args.file}")
        return 1
    print("Events:", json.dumps(report["events"], sort_keys=True))
    for rec in report["refusals"]:
        print(f"  refused at {rec.get('ts')}: name={rec.get('name')!r} reason={rec.get('reason')!r}")
    alerts = list(report["alerts"])
    if args.webui_log:
        if args.webui_log == "-":
            webui = summarize_webui(sys.stdin)
        else:
            with open(args.webui_log, encoding="utf-8", errors="replace") as fh:
                webui = summarize_webui(fh)
        print("Open WebUI:", json.dumps(webui["events"], sort_keys=True))
        for rec in webui["signin_failures"]:
            print(f"  failed sign-in at {rec['ts']} (HTTP {rec['status']})")
        alerts += webui["alerts"]
    for alert in alerts:
        print("ALERT:", alert)
    if not alerts:
        print("No alerts.")
    return 2 if alerts else 0


if __name__ == "__main__":
    sys.exit(main())
