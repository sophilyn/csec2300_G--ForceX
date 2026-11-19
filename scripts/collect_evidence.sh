#!/usr/bin/env bash
# Incident evidence collection for the G-ForceX stack (Control 7: Incident Response Plan).
#
# Takes a read-only snapshot of what investigators need, BEFORE anything is changed:
# container state, image IDs, networks, the Compose config (without secret values), the agent's
# audit log, a log review with alerts, recent Docker logs, and a firewall test. Every file gets a
# SHA-256 hash in MANIFEST.sha256 (chain of custody) and is made read-only.
#
# Usage (from the repository root, stack running):
#     bash scripts/collect_evidence.sh                         # incident ID "INCIDENT", last 24h of logs
#     bash scripts/collect_evidence.sh --incident IR-2026-001 --since 2h
#     bash scripts/collect_evidence.sh --dest /Volumes/USB/GForceX-Incidents
# Verify later:  cd <evidence folder> && shasum -a 256 -c MANIFEST.sha256
#
# The folder is private (mode 700, files 400). The Open WebUI secret key is never written: the Compose
# config is saved without interpolation, and every file is checked for the key and redacted if found.
set -uo pipefail
umask 077

ID="INCIDENT"; SINCE="24h"; DEST="${HOME}/GForceX-Incidents"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --incident) ID="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$ID" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || { echo "Incident ID may use letters, digits, . _ - only." >&2; exit 2; }

cd "$(dirname "$0")/.."
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$DEST/$ID-$STAMP"
mkdir -p "$DEST" && chmod 700 "$DEST" && mkdir "$OUT" && chmod 700 "$OUT"
step() { echo "  $1"; }
echo "Collecting evidence for $ID into $OUT"

step "metadata"
{
  echo "incident_id: $ID"
  echo "collected_utc: $STAMP"
  echo "log_window: $SINCE"
  echo "host_os: $(uname -sr)"
  echo "docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  echo "git_commit: $(git rev-parse HEAD 2>/dev/null)"
  echo "git_branch: $(git branch --show-current 2>/dev/null)"
  echo "git_uncommitted_files: $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
} > "$OUT/01-metadata.txt"

step "container state and image IDs"
docker compose ps -a --format json > "$OUT/02-containers.json" 2>/dev/null
for c in $(docker compose ps -aq 2>/dev/null); do
  docker inspect -f '{{.Name}} image={{.Config.Image}} image_id={{.Image}} started={{.State.StartedAt}} status={{.State.Status}} restarts={{.RestartCount}}' "$c"
done > "$OUT/03-images.txt" 2>/dev/null

step "compose config (no secret values) and networks"
docker compose config --no-interpolate > "$OUT/04-compose-config.yml" 2>/dev/null
PROJECT=$(docker compose ps --format '{{.Project}}' 2>/dev/null | head -1)
for net in $(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT"); do
  docker network inspect -f '{{.Name}} internal={{.Internal}} containers={{range .Containers}}{{.Name}} {{end}}' "$net"
done > "$OUT/05-networks.txt" 2>/dev/null

step "agent audit log"
mkdir "$OUT/06-audit"
for f in audit.jsonl audit.jsonl.1 audit.jsonl.2 audit.jsonl.3 audit.jsonl.4 audit.jsonl.5; do
  docker compose exec -T adk-agent sh -c "test -f /var/log/gforcex/$f && cat /var/log/gforcex/$f" \
    > "$OUT/06-audit/$f" 2>/dev/null || rm -f "$OUT/06-audit/$f"
done

step "log review (alerts)"
bash tests/logging/review_logs.sh "$SINCE" > "$OUT/07-log-review.txt" 2>&1
echo "review_exit_code: $?" >> "$OUT/07-log-review.txt"

step "Docker logs (last $SINCE)"
for svc in $(docker compose config --services 2>/dev/null); do
  docker compose logs --no-color --timestamps --since "$SINCE" "$svc" > "$OUT/08-docker-logs-$svc.txt" 2>/dev/null
done

step "firewall test"
bash tests/network/check_network.sh > "$OUT/09-network-test.txt" 2>&1
echo "network_test_exit_code: $?" >> "$OUT/09-network-test.txt"

step "secret check"
# Compare against the real key without printing it; redact any copy that slipped into the evidence.
key=$(grep -s '^WEBUI_SECRET_KEY=' .env | head -1 | cut -d= -f2-)
redacted=0
if [[ -n "$key" ]]; then
  while IFS= read -r f; do
    LC_ALL=C sed -i.bak "s/$(printf '%s' "$key" | sed 's/[][\.*^$/]/\\&/g')/[REDACTED-SECRET-KEY]/g" "$f" && rm -f "$f.bak"
    redacted=$((redacted + 1))
  done < <(grep -rlF -- "$key" "$OUT" 2>/dev/null)
fi
unset key
echo "secret_key_copies_redacted: $redacted" >> "$OUT/01-metadata.txt"

step "hashes and read-only"
(cd "$OUT" && find . -type f ! -name MANIFEST.sha256 | sort | while read -r f; do shasum -a 256 "$f"; done > MANIFEST.sha256)
find "$OUT" -type f -exec chmod 400 {} +
find "$OUT" -mindepth 1 -type d -exec chmod 500 {} +

echo "Evidence saved: $OUT ($(find "$OUT" -type f | wc -l | tr -d ' ') files)"
echo "Verify with:    (cd \"$OUT\" && shasum -a 256 -c MANIFEST.sha256)"
