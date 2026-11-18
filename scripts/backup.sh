#!/usr/bin/env bash
# Encrypted backup of the G-ForceX stack (Control 3: Data Backup and Recovery).
#
# Backs up every Docker volume of this Compose project (Open WebUI database and files,
# Ollama models, agent audit log) plus the configuration needed to rebuild it
# (docker-compose.yml, .env, approved documents). The result is ONE file encrypted with
# AES-256 (key derived from your passphrase with PBKDF2, 600,000 iterations), stored
# outside the repository with owner-only permissions, plus a SHA-256 checksum file.
#
# Usage (from the repository root):
#     bash scripts/backup.sh                       # asks for a passphrase twice
#     bash scripts/backup.sh --dest /Volumes/USB/GForceX-Backups
#     BACKUP_PASSPHRASE_FILE=/path/to/file bash scripts/backup.sh   # for automation/tests
#
# The app is stopped during the backup (about 1-5 minutes) so the database is consistent,
# then restarted. Keep the passphrase somewhere safe: without it the backup cannot be restored.
set -euo pipefail
umask 077

DEST="${HOME}/GForceX-Backups"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
HELPER_IMAGE="python:3.12.16-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b"
PROJECT=$(docker compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$DEST/gforcex-backup-$STAMP.tar.enc"

mkdir -p "$DEST" && chmod 700 "$DEST"
WORK=$(mktemp -d "$DEST/.work-XXXXXX")
running=$(docker compose ps --services --status running 2>/dev/null || true)

cleanup() {
  rm -rf "$WORK"
  if [[ -n "$running" ]]; then
    echo "Restarting: $(echo $running)"
    docker compose start $running >/dev/null 2>&1 || echo "WARNING: could not restart services; run: docker compose up -d" >&2
  fi
}
trap cleanup EXIT

# Passphrase: from a file (automation) or typed twice. Never printed or logged.
PASSFILE="$WORK/.pass"
if [[ -n "${BACKUP_PASSPHRASE_FILE:-}" ]]; then
  cp "$BACKUP_PASSPHRASE_FILE" "$PASSFILE"
else
  read -r -s -p "Backup passphrase (min 12 characters): " p1; echo
  read -r -s -p "Repeat passphrase: " p2; echo
  [[ "$p1" == "$p2" ]] || { echo "Passphrases do not match." >&2; exit 1; }
  printf '%s' "$p1" > "$PASSFILE"; unset p1 p2
fi
[[ $(wc -c < "$PASSFILE") -ge 12 ]] || { echo "Passphrase must be at least 12 characters." >&2; exit 1; }

echo "Backing up project '$PROJECT' to $OUT"
mkdir -p "$WORK/data/volumes" "$WORK/data/config"

if [[ -n "$running" ]]; then
  echo "Stopping services for a consistent backup: $(echo $running)"
  docker compose stop >/dev/null 2>&1
fi

volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")
[[ -n "$volumes" ]] || { echo "No volumes found for project $PROJECT." >&2; exit 1; }
for vol in $volumes; do
  short="${vol#"${PROJECT}"_}"
  echo "  volume $short ..."
  docker run --rm --network none -v "$vol:/data:ro" -v "$WORK/data/volumes:/backup" "$HELPER_IMAGE" \
    sh -c "tar -C /data -cf /backup/$short.tar . && chown $(id -u):$(id -g) /backup/$short.tar"
done

echo "  configuration ..."
cp docker-compose.yml "$WORK/data/config/"
[[ -f .env ]] && cp .env "$WORK/data/config/.env"
cp approved_class_notes.txt "$WORK/data/config/" 2>/dev/null || true

# Manifest: what is inside, plus a SHA-256 of every file. Restore checks these hashes,
# so corruption or tampering inside the encrypted archive is detected.
IMAGES=$(docker compose config --images 2>/dev/null | tr '\n' ' ')   # read here: the subshell below changes folder
(
  cd "$WORK/data"
  {
    echo "G-ForceX backup"
    echo "created_utc: $STAMP"
    echo "project: $PROJECT"
    echo "volumes: $(echo $volumes | sed "s/${PROJECT}_//g")"
    echo "images: $IMAGES"
    echo "sha256:"
  } > MANIFEST.txt
  find . -type f ! -name MANIFEST.txt | sort | while read -r f; do
    shasum -a 256 "$f"
  done >> MANIFEST.txt
)

echo "  encrypting (AES-256-CBC, PBKDF2 600000 iterations) ..."
tar -C "$WORK/data" -cf - . | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "file:$PASSFILE" -out "$OUT"
chmod 600 "$OUT"
(cd "$DEST" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256" && chmod 600 "$(basename "$OUT").sha256")

echo "Backup complete: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Checksum:        $OUT.sha256"
