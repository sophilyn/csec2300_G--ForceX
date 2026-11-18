#!/usr/bin/env bash
# Live audit-log test for the G-ForceX stack (Control 2: Security Monitoring and Audit Logs).
#
# 1. Generates test events: one real agent question (containing a fake password) and
#    three attempts to read unapproved files.
# 2. Reviews the audit log and checks the events were recorded, secrets were redacted,
#    no document contents were logged, and the audit report raises an alert.
# 3. Checks Docker log size limits, log-folder permissions, and that the log survives a restart.
#
# Run from the repository root with the stack running (needs Ollama; takes about 1-2 minutes):
#     bash tests/logging/check_audit_logs.sh
set -u
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
agent() { docker compose exec -T adk-agent "$@" 2>/dev/null; }

FAKE_SECRET="Hunter2-audit-test"
since=$(agent python -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat(timespec="milliseconds"))')
echo "== Generating test events (since $since) =="
agent python -m gforcex_agent.run_query "Audit test: what is the fictional lab network named? my password=$FAKE_SECRET" >/dev/null \
  && echo "asked one real question" || echo "question run returned an error (it should still be audited)"
agent python -c '
from gforcex_agent.tools import read_approved_document
for name in ("../unapproved_policy.txt", "/etc/passwd", "unapproved_policy.txt"):
    read_approved_document(name)' && echo "made 3 attempts to read unapproved files"

log=$(agent python -c "
import json, sys
for line in open('/var/log/gforcex/audit.jsonl', encoding='utf-8'):
    try:
        if json.loads(line).get('ts', '') >= sys.argv[1]:
            sys.stdout.write(line)
    except ValueError:
        sys.stdout.write(line)  # keep bad lines so the JSON check below reports them
" "$since")
echo "== Reviewing $(printf '%s\n' "$log" | grep -c . ) new audit log lines =="
has() { printf '%s\n' "$log" | grep -q -- "$1"; }
count() { printf '%s\n' "$log" | grep -c -- "$1"; }

check "every line is valid JSON with a UTC timestamp and an event name" \
  "printf '%s\n' \"\$log\" | python3 -c 'import json,sys; [ (lambda r: r[\"ts\"].endswith(\"+00:00\") and r[\"event\"] or sys.exit(1))(json.loads(l)) for l in sys.stdin if l.strip()]'"
check "question was recorded (query_received with its text)"    'has "\"event\": \"query_received\".*Audit test: what is the fictional lab network named"'
check "fake password in the question was redacted"               'has "password=\[REDACTED\]" && ! has "$FAKE_SECRET"'
check "approved document access was recorded (document_served)"  'has "\"event\": \"document_served\", \"name\": \"approved_class_notes.txt\""'
check "query outcome was recorded (query_completed, tools used)" 'has "\"event\": \"query_completed\".*get_approved_documents"'
check "3 unapproved-file attempts were recorded (access_refused)" '[ "$(count "\"event\": \"access_refused\"")" -eq 3 ]'
check "no document contents in the log"                          '! has "A switch connects devices" && ! has "Maple-739"'
check "model answer text is not logged (only its length)"        '! has "is named Bluebird"'

report=$(agent python -m gforcex_agent.audit_report --since "$since"); report_rc=$?
echo "$report" | sed 's/^/      report: /'
check "audit report raises an alert for the refused attempts (exit code 2)" '[ "$report_rc" -eq 2 ] && echo "$report" | grep -q "ALERT: 3 refused"'

qid=$(printf '%s\n' "$log" | grep '"event": "query_received"' | head -1 | sed -E 's/.*"query_id": "([0-9a-f]+)".*/\1/')
check "document access is linked to the question that caused it (same query_id $qid)" \
  '[ -n "$qid" ] && has "\"event\": \"document_served\".*\"query_id\": \"$qid\""'

echo "== Open WebUI sign-in monitoring =="
# 5 sign-ins with a fake account and fake password, sent inside the Open WebUI container to its own port.
webui_since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker compose exec -T open-webui python -c '
import json, urllib.request, urllib.error
for i in range(5):
    req = urllib.request.Request("http://localhost:8080/api/v1/auths/signin", method="POST",
        data=json.dumps({"email": "audit-test-%d@example.invalid" % i, "password": "not-a-real-password"}).encode(),
        headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError:
        pass' 2>/dev/null && echo "made 5 failed sign-in attempts with a fake account"
sleep 2
webui_report=$(docker compose logs --no-log-prefix --no-color --since "$webui_since" open-webui 2>/dev/null \
  | agent python -m gforcex_agent.audit_report --since "$since" --webui-log -)
echo "$webui_report" | grep -E 'Open WebUI|ALERT: .*sign-ins' | sed 's/^/      report: /'
check "failed sign-ins were recorded and the report raises an alert" \
  'echo "$webui_report" | grep -q "\"signin_failed\": 5" && echo "$webui_report" | grep -q "possible password guessing"'
check "the fake password does not appear in Open WebUI logs" \
  '! docker compose logs --since "$webui_since" open-webui 2>/dev/null | grep -q "not-a-real-password"'
review=$(bash tests/logging/review_logs.sh 1h 2>&1); review_rc=$?
check "combined review script runs and reports alerts (exit code 2)" \
  '[ "$review_rc" -eq 2 ] && echo "$review" | grep -q "G-ForceX log review"'

echo "== Log storage =="
for svc in ollama open-webui adk-agent; do
  cfg=$(docker inspect -f '{{json .HostConfig.LogConfig.Config}}' "$(docker compose ps -q "$svc" 2>/dev/null)" 2>/dev/null)
  check "$svc Docker logs are size-limited ($cfg)" 'echo "$cfg" | grep -q "\"max-size\":\"10m\"" && echo "$cfg" | grep -q "\"max-file\":\"3\""'
done
perms=$(agent stat -c '%a %u' /var/log/gforcex)
check "audit log folder is private to the agent user (mode 700, UID 10001): got '$perms'" '[ "$perms" = "700 10001" ]'
before=$(agent sh -c 'wc -l < /var/log/gforcex/audit.jsonl')
docker compose restart adk-agent >/dev/null 2>&1
after=$(agent sh -c 'wc -l < /var/log/gforcex/audit.jsonl')
check "audit log survives a container restart ($before lines before, $after after)" '[ -n "$after" ] && [ "$after" -ge "$before" ] && [ "$before" -gt 0 ]'

echo "== Result: $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
