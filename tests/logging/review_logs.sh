#!/usr/bin/env bash
# Log review for the G-ForceX stack (Control 2: Security Monitoring and Audit Logs, detective part).
#
# Reviews both logs in one report and raises ALERT lines for:
#   * 3+ refused document requests to the ADK agent (attempt to read unapproved files)
#   * failed agent queries, audit errors, or audit lines that are not valid JSON (tampering)
#   * 5+ failed Open WebUI sign-ins (password guessing)
# Run from the repository root with the stack running:
#     bash tests/logging/review_logs.sh            # last 24 hours
#     bash tests/logging/review_logs.sh 2h         # any "docker compose logs --since" value
# Exit code: 0 = no alerts, 2 = alerts, 1 = could not review.
set -u
window="${1:-24h}"
since=$(docker compose exec -T adk-agent python -c "
import re, sys
from datetime import datetime, timedelta, timezone
m = re.fullmatch(r'(\d+)([smhd])', sys.argv[1])
if not m: sys.exit('window must look like 30m, 2h or 1d')
unit = {'s': 'seconds', 'm': 'minutes', 'h': 'hours', 'd': 'days'}[m[2]]
print((datetime.now(timezone.utc) - timedelta(**{unit: int(m[1])})).isoformat(timespec='milliseconds'))
" "$window" | tr -d '\r') || { echo "Could not reach the ADK agent container. Is the stack running?"; exit 1; }

echo "== G-ForceX log review: last $window (since $since) =="
docker compose logs --no-log-prefix --no-color --since "$window" open-webui 2>/dev/null \
  | docker compose exec -T adk-agent python -m gforcex_agent.audit_report --since "$since" --webui-log -
