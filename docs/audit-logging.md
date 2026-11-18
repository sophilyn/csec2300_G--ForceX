# Control 2: Security monitoring and audit logs

**Type:** Detective · **SY0-701:** 4.0 Security Operations · **Status:** implemented and tested on 2026-11-17

## Goal (from our control plan)
> Use application and Docker logs to record relevant events. Avoid recording passwords, credentials,
> or private document contents. Generate test events, review the logs, and verify that relevant
> activity is recorded.

## What was missing before
- **Questions asked to the ADK agent left no record.** The command-line runner logged only to the
  terminal that ran it, not to Docker's logs or any file.
- **Docker logs had no size limit** (`"Config":{}` on all 3 containers), so they could grow until the disk was full.
- **There was no log review:** nothing checked that events were recorded or that secrets stayed out.

## What was added

### 1. Agent audit log (`agent/gforcex_agent/audit.py`)
One JSON object per line, in UTC, written to `/var/log/gforcex/audit.jsonl` inside the agent container
and also to the container's error output.

| Event | When | Fields |
|---|---|---|
| `query_received` | A question is asked | `query_id`, `source`, `question` (text), `question_chars` |
| `query_retried` | The model printed its tool call and the agent retried | `query_id`, `reason` |
| `query_completed` | An answer was produced | `query_id`, `tools_called`, `retried`, `answer_chars`, `duration_ms` |
| `query_failed` | The query crashed (for example an Ollama timeout) | `query_id`, `error` type, `duration_ms` |
| `documents_listed` / `documents_returned` / `documents_truncated` | The document tool ran | counts, size limit |
| `document_served` | An approved document was read | `name`, `bytes` |
| `access_refused` | A request for a file that is not approved | requested `name`, `reason` |

**Privacy rules:**
- **Question text is logged.** This was a team decision on 2026-11-17, to make investigations possible.
- Before writing, anything that looks like a password, key or token is replaced with `[REDACTED]`. This covers `password=…`, `api_key: …`, `sk-…`, GitHub `ghp_…`, AWS `AKIA…`, JWTs, and long hex keys.
- Any field longer than 500 characters is cut off.
- **Never logged:** document contents and the model's answers. Only their lengths are recorded.
- Newlines and control characters are escaped, so a question cannot forge extra log entries (log injection).

**Storage:**
- The log lives on the Docker volume `agent_audit`, so it survives restarts.
- It rotates at 5 MB and keeps 5 old files.
- The folder is mode `700`, owned by the agent's non-root user (UID 10001).
- The rest of the container stays read-only.

### 2. Audit report: the detective part (`python -m gforcex_agent.audit_report`)
The report counts events and raises an **ALERT** (exit code 2) for:
- 3 or more refused document requests, which may be an attempt to read unapproved files;
- failed queries or audit errors;
- log lines that are not valid JSON, which may mean tampering or corruption.

```bash
docker compose exec adk-agent python -m gforcex_agent.audit_report
```

### 3. Docker log size limits (`docker-compose.yml`)
All 3 containers use `json-file` with `max-size: 10m` and `max-file: 3`. CI fails any pull request that removes these limits.

## How to test
```bash
bash tests/logging/check_audit_logs.sh   # live test, needs the stack running (about 1-2 minutes)
python3 -m unittest discover -s agent/tests -t agent   # unit tests, no Docker needed
```

## Evidence (macOS, Docker 29.7.2)
Live test: **14 passed, 0 failed**, exit code 0.
```
== Generating test events (since 2026-11-17T20:41:30.718+00:00) ==
asked one real question
made 3 attempts to read unapproved files
== Reviewing 8 new audit log lines ==
PASS  every line is valid JSON with a UTC timestamp and an event name
PASS  question was recorded (query_received with its text)
PASS  fake password in the question was redacted
PASS  approved document access was recorded (document_served)
PASS  query outcome was recorded (query_completed, tools used)
PASS  3 unapproved-file attempts were recorded (access_refused)
PASS  no document contents in the log
PASS  model answer text is not logged (only its length)
      report: Events: {"access_refused": 3, "document_served": 1, "documents_listed": 1, "documents_returned": 1, "query_completed": 1, "query_received": 1}
      report:   refused at 2026-11-17T20:42:02.365+00:00: name="'../unapproved_policy.txt'" reason='Invalid document name'
      report:   refused at 2026-11-17T20:42:02.366+00:00: name="'/etc/passwd'" reason='Invalid document name'
      report:   refused at 2026-11-17T20:42:02.366+00:00: name="'unapproved_policy.txt'" reason='Document is not on the approved list'
      report: ALERT: 3 refused document requests (threshold 3): possible attempt to read unapproved files
PASS  audit report raises an alert for the refused attempts (exit code 2)
== Log storage ==
PASS  ollama Docker logs are size-limited ({"max-file":"3","max-size":"10m"})
PASS  open-webui Docker logs are size-limited ({"max-file":"3","max-size":"10m"})
PASS  adk-agent Docker logs are size-limited ({"max-file":"3","max-size":"10m"})
PASS  audit log folder is private to the agent user (mode 700, UID 10001): got '700 10001'
PASS  audit log survives a container restart (8 lines before, 8 after)
== Result: 14 passed, 0 failed ==
```

Sample audit lines from that run (the question contained `password=Hunter2-audit-test`):
```
{"ts": "2026-11-17T20:41:32.987+00:00", "event": "query_received", "query_id": "f86f9ce4a83d", "source": "cli", "question": "Audit test: what is the fictional lab network named? my password=[REDACTED]", "question_chars": 83}
{"ts": "2026-11-17T20:41:52.048+00:00", "event": "document_served", "name": "approved_class_notes.txt", "bytes": 167}
{"ts": "2026-11-17T20:41:59.722+00:00", "event": "query_completed", "query_id": "f86f9ce4a83d", "tools_called": ["get_approved_documents"], "retried": false, "answer_chars": 44, "duration_ms": 26736}
{"ts": "2026-11-17T20:42:02.365+00:00", "event": "access_refused", "name": "'../unapproved_policy.txt'", "reason": "Invalid document name"}
```

**Unit tests** (`agent/tests/test_audit.py`, 11 tests, run in CI) cover:
- JSON format and UTC timestamps;
- that question text is kept;
- redaction of 5 secret types;
- that newlines cannot forge entries;
- truncation;
- that document tools log names and never contents;
- the fallback when the log folder is missing;
- the report's alerts and time filter.

**CI check:** the log-size rule passes on the new Compose file and fails on the old one: "services without log size limits: adk-agent, ollama, open-webui".

## Open WebUI logs
- Open WebUI's own application logs were tested by the team (issue #15).
- They now go through Docker's size-limited logs:
  ```bash
  docker compose logs open-webui
  ```

## Limitations
- **Logged questions are sensitive data.** Redaction catches common secret formats, not every possible secret or personal detail. Treat the audit volume as private.
- `document_served` and `access_refused` events have no `query_id`. Match them to a query by timestamp.
- The agent's HTTP API (`adk api_server`, internal network only) records document events but not question text. Only the command-line runner records `query_*` events.
- Logs stay on the same machine. There is no central log server, and nobody is paged on an alert; the report must be run by hand.
- The log is not tamper-proof. Anyone with Docker access on the host can edit it. The report flags lines that are not valid JSON, but cannot detect careful edits.
