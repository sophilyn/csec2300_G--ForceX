#!/usr/bin/env bash
# Backup and recovery drill for the G-ForceX stack (Control 3: Data Backup and Recovery).
#
# 1. Stops the app and fingerprints every live Docker volume (SHA-256 of every file).
# 2. Makes a real encrypted backup with scripts/backup.sh (into a temporary folder).
# 3. Checks the backup is encrypted, private, and has no readable secrets or document text.
# 4. Checks a wrong passphrase and a tampered backup are both refused, and change nothing.
# 5. Restores into SEPARATE drill volumes (project "gforcex-drill") and checks every file matches.
# 6. Starts Open WebUI and Ollama from the restored data to prove the app really recovers.
# 7. Cleans up the drill volumes, containers and temporary backup, and restarts the app.
#
# Live data is only read, never changed. Needs about 2x the data size in free disk space.
# Run from the repository root (takes about 5-10 minutes with the Ollama models):
#     bash tests/backup/check_backup_restore.sh
set -u
cd "$(dirname "$0")/../.."
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

HELPER_IMAGE="python:3.12.16-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b"
PROJECT=$(docker compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
DRILL="gforcex-drill"
TMP=$(mktemp -d "${HOME}/.gforcex-drill-XXXXXX"); chmod 700 "$TMP"
openssl rand -base64 32 > "$TMP/pass" && openssl rand -base64 32 > "$TMP/wrongpass"   # throwaway, never printed

cleanup() {
  docker rm -f gforcex-drill-webui gforcex-drill-ollama >/dev/null 2>&1
  for v in $(docker volume ls -q --filter "label=com.docker.compose.project=$DRILL"; \
             docker volume ls -q --filter "label=com.docker.compose.project=gforcex-tamper"); do
    docker volume rm "$v" >/dev/null 2>&1
  done
  rm -rf "$TMP"
  docker compose up -d >/dev/null 2>&1 && echo "(cleanup done; app restarted)"
}
trap cleanup EXIT

fingerprint() {  # fingerprint <volume> -> "<files> files, sha256 <hash of all file hashes>"
  docker run --rm --network none -v "$1:/data:ro" "$HELPER_IMAGE" sh -c \
    'cd /data && n=$(find . -type f | wc -l) && h=$(find . -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -c1-16) && echo "$n files, sha256 $h"'
}
db_counts() {  # db_counts <webui volume> -> "users=N chats=M"
  docker run --rm --network none -v "$1:/data:ro" "$HELPER_IMAGE" python -c '
import sqlite3
c = sqlite3.connect("file:/data/webui.db?immutable=1", uri=True)
users = c.execute("select count(*) from user").fetchone()[0]
chats = c.execute("select count(*) from chat").fetchone()[0]
print("users=%d chats=%d" % (users, chats))'
}

echo "== 1. Fingerprint live data (app stopped for a consistent snapshot) =="
docker compose stop >/dev/null 2>&1
: > "$TMP/live.txt"   # lines of "<volume short name>|<fingerprint>" (macOS bash 3.2 has no maps)
for vol in $(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT"); do
  short="${vol#"${PROJECT}"_}"; fp=$(fingerprint "$vol"); echo "$short|$fp" >> "$TMP/live.txt"; echo "      $short: $fp"
done
live_db=$(db_counts "${PROJECT}_webui_data"); echo "      Open WebUI database: $live_db"

echo "== 2. Backup =="
start=$(date +%s)
BACKUP_PASSPHRASE_FILE="$TMP/pass" bash scripts/backup.sh --dest "$TMP/backups" | sed 's/^/      /'
file=$(ls "$TMP"/backups/gforcex-backup-*.tar.enc 2>/dev/null | head -1)
check "backup file created in $(( $(date +%s) - start ))s ($(du -h "$file" 2>/dev/null | cut -f1))" '[ -s "$file" ]'

echo "== 3. Backup is protected =="
check "backup file is encrypted (OpenSSL salted AES format)"          '[ "$(head -c 8 "$file")" = "Salted__" ]'
check "backup file and folder are owner-only (600 / 700)"             '[ "$(stat -f %Lp "$file" 2>/dev/null || stat -c %a "$file")" = 600 ] && [ "$(stat -f %Lp "$TMP/backups" 2>/dev/null || stat -c %a "$TMP/backups")" = 700 ]'
check "no readable secret key name or document text inside the file" '! LC_ALL=C grep -a -q -e WEBUI_SECRET_KEY -e "The fictional lab network" "$file"'
check "SHA-256 checksum file written next to the backup"              '[ -s "$file.sha256" ]'

echo "== 4. Bad restores are refused and change nothing =="
BACKUP_PASSPHRASE_FILE="$TMP/wrongpass" bash scripts/restore.sh "$file" --project gforcex-tamper --yes --config-out "$TMP/cfg-wrong" >"$TMP/wrong.log" 2>&1; rc=$?
check "wrong passphrase is refused (exit $rc: $(grep -m1 FAILED "$TMP/wrong.log"))" '[ $rc -ne 0 ] && grep -q "could not decrypt" "$TMP/wrong.log"'
cp -c "$file" "$TMP/tampered.tar.enc" 2>/dev/null || cp "$file" "$TMP/tampered.tar.enc"
python3 - "$TMP/tampered.tar.enc" <<'EOF'
import os, sys
path = sys.argv[1]
with open(path, "r+b") as f:          # flip one byte in the middle of the encrypted data
    f.seek(os.path.getsize(path) // 2); b = f.read(1); f.seek(-1, 1); f.write(bytes([b[0] ^ 0xFF]))
EOF
cp "$file.sha256" "$TMP/tampered.tar.enc.sha256"
BACKUP_PASSPHRASE_FILE="$TMP/pass" bash scripts/restore.sh "$TMP/tampered.tar.enc" --project gforcex-tamper --yes --config-out "$TMP/cfg-t1" >"$TMP/t1.log" 2>&1; rc=$?
check "tampered backup is refused by the checksum (exit $rc)" '[ $rc -ne 0 ] && grep -q "checksum mismatch" "$TMP/t1.log"'
(cd "$TMP" && shasum -a 256 tampered.tar.enc > tampered.tar.enc.sha256)   # attacker also fixes the checksum
BACKUP_PASSPHRASE_FILE="$TMP/pass" bash scripts/restore.sh "$TMP/tampered.tar.enc" --project gforcex-tamper --yes --config-out "$TMP/cfg-t2" >"$TMP/t2.log" 2>&1; rc=$?
check "tampered backup with a forged checksum is still refused (exit $rc: $(grep -m1 FAILED "$TMP/t2.log"))" '[ $rc -ne 0 ] && grep -q FAILED "$TMP/t2.log"'
rm -f "$TMP/tampered.tar.enc"
check "refused restores created no volumes" '[ -z "$(docker volume ls -q --filter label=com.docker.compose.project=gforcex-tamper)" ]'

echo "== 5. Restore into separate drill volumes =="
BACKUP_PASSPHRASE_FILE="$TMP/pass" bash scripts/restore.sh "$file" --project "$DRILL" --yes --config-out "$TMP/cfg" | sed 's/^/      /'
while IFS='|' read -r short expected; do
  restored=$(fingerprint "${DRILL}_${short}" </dev/null)
  check "$short restored identical: $restored" '[ "$restored" = "$expected" ]'
done < "$TMP/live.txt"
drill_db=$(db_counts "${DRILL}_webui_data")
check "Open WebUI database restored with the same accounts and chats ($drill_db)" '[ "$drill_db" = "$live_db" ]'
check "configuration restored (.env matches, compared without printing it)" 'cmp -s .env "$TMP/cfg/.env" && cmp -s docker-compose.yml "$TMP/cfg/docker-compose.yml"'

echo "== 6. The app runs from the restored data =="
webui_image=$(docker compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["open-webui"]["image"])')
ollama_image=$(docker compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["ollama"]["image"])')
docker run -d --name gforcex-drill-ollama -v "${DRILL}_ollama_data:/root/.ollama" "$ollama_image" >/dev/null
docker run -d --name gforcex-drill-webui -p 127.0.0.1:3901:8080 --env-file "$TMP/cfg/.env" \
  -v "${DRILL}_webui_data:/app/backend/data" "$webui_image" >/dev/null
health=$(python3 - <<'EOF'
import time, urllib.request
for _ in range(90):
    try:
        print(urllib.request.urlopen("http://127.0.0.1:3901/health", timeout=3).status); break
    except Exception:
        time.sleep(2)
else:
    print("no response")
EOF
)
check "restored Open WebUI starts and is healthy (HTTP $health on drill port 3901)" '[ "$health" = 200 ]'
models=$(docker exec gforcex-drill-ollama ollama list 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' ')
check "restored Ollama has the model without downloading (models: $models)" 'echo "$models" | grep -q "llama3.2:3b"'

echo "== Result: $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
