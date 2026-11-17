#!/usr/bin/env bash
# Restore a G-ForceX backup made by scripts/backup.sh (Control 3: Data Backup and Recovery).
#
# Steps: 1) check the file's SHA-256 checksum, 2) decrypt with your passphrase,
# 3) check the SHA-256 of every file against the backup's manifest, 4) restore each
# Docker volume, 5) write the configuration files to a private folder for review.
# Any failed check stops the restore before anything is changed.
#
# Usage (from the repository root):
#     bash scripts/restore.sh BACKUP_FILE                 # restore into this project (asks to confirm)
#     bash scripts/restore.sh BACKUP_FILE --project NAME  # restore into separate volumes (drills)
#     options: --yes (do not ask), --config-out DIR (where config files go)
#     BACKUP_PASSPHRASE_FILE=/path/to/file for automation/tests
#
# Restoring into this project REPLACES the current data in its volumes. The app is stopped first.
set -euo pipefail
umask 077

BACKUP="${1:-}"; [[ -n "$BACKUP" && -f "$BACKUP" ]] || { echo "Usage: bash scripts/restore.sh BACKUP_FILE [--project NAME] [--yes] [--config-out DIR]" >&2; exit 2; }
shift
TARGET=""; ASSUME_YES=0; CONFIG_OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) TARGET="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --config-out) CONFIG_OUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

BACKUP=$(cd "$(dirname "$BACKUP")" && pwd)/$(basename "$BACKUP")
cd "$(dirname "$0")/.."
HELPER_IMAGE="python:3.12.16-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b"
CURRENT=$(docker compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
TARGET="${TARGET:-$CURRENT}"
CONFIG_OUT="${CONFIG_OUT:-$(dirname "$BACKUP")/restored-config-$(date -u +%Y%m%dT%H%M%SZ)}"

WORK=$(mktemp -d "$(dirname "$BACKUP")/.restore-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

echo "1/5 Checking file checksum ..."
if [[ -f "$BACKUP.sha256" ]]; then
  expected=$(cut -d' ' -f1 < "$BACKUP.sha256")
  actual=$(shasum -a 256 "$BACKUP" | cut -d' ' -f1)
  [[ "$expected" == "$actual" ]] || { echo "FAILED: checksum mismatch. The backup file is corrupted or was modified." >&2; exit 1; }
  echo "    OK"
else
  echo "    WARNING: no .sha256 file next to the backup; skipping this check (the manifest check still runs)"
fi

echo "2/5 Decrypting ..."
PASSFILE="$WORK/.pass"
if [[ -n "${BACKUP_PASSPHRASE_FILE:-}" ]]; then
  cp "$BACKUP_PASSPHRASE_FILE" "$PASSFILE"
else
  read -r -s -p "Backup passphrase: " p1; echo
  printf '%s' "$p1" > "$PASSFILE"; unset p1
fi
mkdir "$WORK/data"
if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:$PASSFILE" -in "$BACKUP" 2>/dev/null \
     | tar -C "$WORK/data" -xf - 2>/dev/null; then
  echo "FAILED: could not decrypt. Wrong passphrase or damaged file." >&2; exit 1
fi
[[ -f "$WORK/data/MANIFEST.txt" ]] || { echo "FAILED: decrypted data has no manifest. Wrong passphrase or damaged file." >&2; exit 1; }
echo "    OK"

echo "3/5 Verifying every file against the manifest ..."
(cd "$WORK/data" && sed -n '/^sha256:$/,$p' MANIFEST.txt | tail -n +2 | shasum -a 256 -c --quiet -) \
  || { echo "FAILED: a file does not match the manifest. The backup is damaged or was tampered with." >&2; exit 1; }
listed=$(sed -n '/^sha256:$/,$p' "$WORK/data/MANIFEST.txt" | tail -n +2 | wc -l | tr -d ' ')
present=$(cd "$WORK/data" && find . -type f ! -name MANIFEST.txt | wc -l | tr -d ' ')
[[ "$listed" == "$present" ]] || { echo "FAILED: manifest lists $listed files but the backup has $present." >&2; exit 1; }
echo "    OK ($listed files verified)"
sed -n '1,5p' "$WORK/data/MANIFEST.txt" | sed 's/^/    /'

echo "4/5 Restoring Docker volumes into project '$TARGET' ..."
if [[ "$TARGET" == "$CURRENT" && $ASSUME_YES -eq 0 ]]; then
  read -r -p "This REPLACES the current G-ForceX data. Type RESTORE to continue: " answer
  [[ "$answer" == "RESTORE" ]] || { echo "Cancelled. Nothing was changed."; exit 1; }
fi
if [[ "$TARGET" == "$CURRENT" ]]; then
  docker compose stop >/dev/null 2>&1 || true
fi
for tarfile in "$WORK"/data/volumes/*.tar; do
  short=$(basename "$tarfile" .tar)
  vol="${TARGET}_${short}"
  docker volume inspect "$vol" >/dev/null 2>&1 || docker volume create \
    --label "com.docker.compose.project=$TARGET" --label "com.docker.compose.volume=$short" "$vol" >/dev/null
  docker run --rm --network none -v "$vol:/data" -v "$WORK/data/volumes:/backup:ro" "$HELPER_IMAGE" \
    sh -c "find /data -mindepth 1 -delete && tar -C /data -xf /backup/$short.tar"
  echo "    $short -> $vol"
done

echo "5/5 Writing configuration files to $CONFIG_OUT ..."
mkdir -p "$CONFIG_OUT" && chmod 700 "$CONFIG_OUT"
cp -p "$WORK"/data/config/* "$CONFIG_OUT/" 2>/dev/null || true
cp -p "$WORK"/data/config/.env "$CONFIG_OUT/.env" 2>/dev/null || true
echo "    Review them and copy what you need into the repository (for example .env)."
if [[ "$TARGET" == "$CURRENT" ]]; then
  echo "Restore complete. Start the app with: docker compose up -d"
else
  echo "Restore complete into separate project '$TARGET'. Your live data was not changed."
fi
