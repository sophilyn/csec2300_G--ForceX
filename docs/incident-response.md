# Control 7: Incident response runbook

**Type:** Corrective · **SY0-701:** 4.0 Security Operations (incident response) · **Status:** runbook and tested drill, 2026-11-18

This runbook puts the team's **[Incident Response Plan](https://github.com/sophilyn/csec2300_G--ForceX/wiki/G-FORCE-X-%E2%80%93-Incident-Response-Plan)** (Wiki, issue #26) into practice. The Wiki plan says *what* we do. This page gives the exact commands for *how* we do it with this project's tools, and shows a drill that runs every step for real.

Our control plan asked for a checklist covering **detection, investigation, containment, removal of the threat (eradication), recovery, and lessons learned**, tested with a simulated incident. Every step below has a command. All commands run from the repository root.

## Roles and notification
| Who | When |
|---|---|
| **Incident lead:** whoever notices the problem first (Karlie or Sophia) | Runs the checklist and keeps the timeline |
| **Second team member** | Notified **immediately** for every incident. Reviews evidence and decisions. |
| **Instructor (Dr. Parra)** | Notified for **High** or **Critical** incidents, as the Wiki plan says |
| Affected users and university IT/security | When their data or accounts may be affected |

| Severity | Examples | Response |
|---|---|---|
| Low | A blocked scan or a single refused request | Note it and review it at the next team check-in |
| Medium | A repeated ALERT, such as 3+ refused document requests or 5+ failed sign-ins, all blocked | Full checklist the same day |
| High | A secret was exposed, or there are signs data was read or changed | Full checklist now, and notify the instructor |
| Critical | Data is lost or encrypted, or there is an active intruder | Stop the stack now, then follow Playbook C, and notify the instructor |

## The checklist

### 1. Detection: how we notice
| Signal | Where to look |
|---|---|
| **Log review ALERT** (refused document requests, failed queries, damaged audit lines, failed Open WebUI sign-ins) | `bash tests/logging/review_logs.sh 24h` (exit code 2 means alerts) |
| A **CI security gate fails** on a pull request (gitleaks, pip-audit, Trivy, bandit, network rules) | The PR's checks on GitHub |
| A **live test fails** (firewall, TLS, audit, backup drill) | `bash tests/network/check_network.sh`, `bash tests/encryption/check_tls.sh` |
| The app is down or behaves strangely, or a person reports something | `docker compose ps`, then the steps below |

Start a timeline right away: write down the time, what you saw, and who noticed it.

### 2. Investigation: collect evidence before changing anything
```bash
bash scripts/collect_evidence.sh --incident IR-2026-001 --since 24h
```
This saves a private, read-only, SHA-256-hashed snapshot to `~/GForceX-Incidents/<ID>-<time>/`. The snapshot contains:
- container state and image IDs;
- networks and the Compose config, **without secret values**;
- the agent's audit log;
- the log review;
- the last Docker logs for every service;
- a firewall test.

Any copy of the Open WebUI secret key that slips into the snapshot is redacted.

To check later that the evidence was not changed:
```bash
cd ~/GForceX-Incidents/IR-2026-001-*/ && shasum -a 256 -c MANIFEST.sha256
```

Then answer these questions:
- **What happened, and when?** Use the audit log: `query_received`, `access_refused`, `document_served` (with `query_id`).
- **Who or what caused it?** Check the Open WebUI sign-ins in the log review.
- **Was any data exposed or changed?**

### 3. Containment: stop it from getting worse
| Situation | Command |
|---|---|
| The ADK agent is misused | `docker compose stop adk-agent` (Open WebUI keeps working) |
| The chat interface is misused, or an account is compromised | `docker compose stop proxy` (the browser path closes), then disable the account in Open WebUI's admin panel |
| Anything serious or unclear | `docker compose stop` (everything stops; data volumes are kept) |
| A secret is exposed | Follow **Playbook A**: rotate it first |

### 4. Eradication: remove the cause
- Fix the root cause: the configuration, an update (`docker compose pull` or a version bump through a PR), or a code fix through a PR so CI checks it.
- Rotate every credential that may be affected (Playbook A).
- Make sure the guardrails hold:
  ```bash
  python3 -m unittest discover -s agent/tests -t agent
  ```
  ```bash
  bash tests/network/check_network.sh
  ```

### 5. Recovery: bring it back safely
```bash
docker compose up -d
```
If data was lost or damaged, restore the last verified backup first (Playbook C). Then confirm everything works:
```bash
bash tests/network/check_network.sh
```
```bash
bash tests/encryption/check_tls.sh
```
```bash
docker compose exec adk-agent python -m gforcex_agent.run_query "What is the fictional lab network named?"
```
Keep watching for 24 hours: run `bash tests/logging/review_logs.sh 24h` again the next day.

### 6. Lessons learned
Within a week, both team members fill in:
- the timeline;
- what worked;
- what was slow or unclear;
- follow-up actions, each with an owner and a due date.

The drill script writes this report template automatically. Turn each follow-up into a GitHub issue.

## Playbooks

### Playbook A: leaked secret (Open WebUI key, backup passphrase, GitHub token)
1. **Rotate the secret immediately.** Deleting it from a file or from Git history is **not** enough, because copies may already exist.
   - **Open WebUI secret key:** this writes a new key without printing it, then restarts Open WebUI. Everyone gets signed out.
     ```bash
     sed -i.bak "s/^WEBUI_SECRET_KEY=.*/WEBUI_SECRET_KEY=$(openssl rand -hex 32)/" .env && rm .env.bak && docker compose up -d open-webui
     ```
   - **Backup passphrase:** make a new backup with a new passphrase (`bash scripts/backup.sh`). Then delete the backups protected by the old passphrase.
   - **GitHub token:** revoke it at GitHub → Settings → Developer settings → Tokens. Check the account's security log.
2. If it was pushed to GitHub, tell the other team member. gitleaks in CI fails the next pull request.
3. Collect evidence (step 2), then complete the lessons learned.

### Playbook B: attempts to read unapproved files, or prompt injection
1. **Detect:** the log review raises `ALERT: N refused document requests`.
2. **Collect evidence:** `bash scripts/collect_evidence.sh --incident <ID> --since <window>`. In `06-audit/audit.jsonl`, find the questions (`query_received`) whose `query_id` matches the refused requests.
3. **Contain:** `docker compose stop adk-agent`.
4. **Eradicate:** confirm that only the approved document is mounted read-only, and that the allowlist tests pass. If an answer leaked data, treat it as **High** and fix the cause through a PR.
5. **Recover:** `docker compose start adk-agent`. Ask a normal question, and confirm unapproved files are still refused.
6. This is the scenario the drill runs (see below).

### Playbook C: lost, damaged or encrypted data
1. `docker compose stop`. Do **not** run any restore yet.
2. Collect evidence, so the damaged state is kept for the investigation.
3. Restore the last verified backup. The restore checks the checksum, the passphrase and every file before changing anything:
   ```bash
   bash scripts/restore.sh ~/GForceX-Backups/gforcex-backup-<time>.tar.enc
   ```
   Full steps are in [backup-recovery.md](backup-recovery.md).
4. `docker compose up -d`, then run the recovery checks in step 5.

## Drill: Playbook B, run for real
```bash
bash tests/incident/run_drill.sh                 # temporary evidence, deleted afterwards
bash tests/incident/run_drill.sh --keep ~/GForceX-Incidents/drills   # keep evidence and report
```
The drill makes the attacker's moves: 4 attempts to read unapproved files, including `../../.env`, and one prompt-injection style question. It then runs every phase with the real tools, checks each one, and writes a timeline and report. Drill events are marked `IR-DRILL` in the audit log. The agent is always restarted at the end.

### Evidence (macOS, Docker 29.7.2, 2026-11-19 UTC)
**16 passed, 0 failed.** It took 62 seconds from attack to verified recovery. In its own words, the agent refused the injection question: *"I can't provide the full contents of unapproved_policy.txt or the internal project code…"*

| Time (UTC) | Event | Duration |
|---|---|---|
| 02:06:28 | Attack simulated (4 file attempts + 1 injection question) | 33 s |
| 02:06:30 | Detected by log review ALERT | 2 s |
| 02:06:36 | Evidence collected and hashed (13 files) | 6 s |
| 02:06:37 | Agent contained (stopped); Open WebUI still served over HTTPS (HTTP 200) | 1 s |
| 02:06:38 | Root cause checked: only the approved file is mounted read-only; allowlist tests pass | 1 s |
| 02:06:57 | Recovered: agent answers normally, still refuses unapproved files, attack records kept, evidence hashes still match | 19 s |

```
PASS  ADK agent, Open WebUI and HTTPS proxy are running
PASS  the agent answered, and did NOT reveal the unapproved document's secret (project code)
PASS  log review raises an ALERT for the refused requests (exit 2)
PASS  evidence folder created and private (mode 700, files read-only 400)
PASS  all evidence files match their SHA-256 hashes (chain of custody)
PASS  audit log copy contains the attack (refused ../../.env attempt)
PASS  the Open WebUI secret key appears in no evidence file (checked without printing it)
PASS  the ADK agent is stopped (attack path closed)
PASS  Open WebUI stays available to users through HTTPS while the agent is contained (HTTP 200)
PASS  only the approved document is mounted, read-only (/var/log/gforcex rw=true;/data/approved/approved_class_notes.txt rw=false;)
PASS  allowlist unit tests pass (traversal, symlink and type checks still enforced)
PASS  agent restarted and answers normal questions ("The fictional lab network is named Bluebird.")
PASS  the allowlist still refuses unapproved files after restart
PASS  the attack records survived the restart in the audit log
PASS  evidence is still intact after recovery
PASS  incident report with timeline written
== Result: 16 passed, 0 failed ==
```

### Lessons learned from the drill (real ones)
1. **The first drill run failed.** The tooling did not trust empty output properly. LiteLLM prints status lines before the agent's JSON answer, so the drill read every answer as empty. Worse, the "secret not revealed" check **passed on an empty answer**, so it would have hidden a real problem. Fix: parse from the JSON line, and treat an empty answer as a failure. **Lesson:** a check that passes when it gets no data is not a check.
2. **The log window can mix incidents.** The 10-minute review counted 9 refused requests, because it included the first run's attempts as well as this run's 4. **Lesson:** record the incident start time, and use a window that starts there (`--since`).
3. **Recovery checks are slow when they ask the model:** about 20–30 seconds per question on CPU. That is fine for a drill, but plan for it when the app must be back quickly.

## Limitations
- Detection runs **only when someone runs the review**. There is no scheduled monitoring and nobody is paged.
- Only Playbook B is drilled with a script. Playbook A (secret rotation) changes real credentials, so it stays a tabletop exercise, as in the Wiki plan. Playbook C reuses the backup drill (`tests/backup/check_backup_restore.sh`).
- Evidence stays on the same computer unless you copy it elsewhere with `--dest`.
- Evidence is hashed but not signed. Someone with access to this computer could change both the files and the manifest.
