"""Summarizes the audit log and flags suspicious activity (Control 2, detective part).

Usage (inside the agent container):
    python -m gforcex_agent.audit_report            # whole current log
    python -m gforcex_agent.audit_report --since 2026-11-17T20:00:00
Exit code 2 when an alert is raised, so the report can be used in scripts.
"""
import argparse
import collections
import json
import os
import sys

REFUSAL_ALERT_THRESHOLD = 3  # refused document requests in one log window


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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", default=os.environ.get("AUDIT_LOG_PATH", "/var/log/gforcex/audit.jsonl"))
    parser.add_argument("--since", default="", help="ISO time; only count events at or after it")
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
    for alert in report["alerts"]:
        print("ALERT:", alert)
    if not report["alerts"]:
        print("No alerts.")
    return 2 if report["alerts"] else 0


if __name__ == "__main__":
    sys.exit(main())
