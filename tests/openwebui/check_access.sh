#!/usr/bin/env bash
# Open WebUI access-control test (Control 4: Access Control and User Permissions).
#
# Checks, through the HTTPS proxy, that:
#   * nobody can create an account by signing up (the admin creates accounts)
#   * only our own HTTPS origin is allowed by CORS
#   * a NORMAL user's permissions forbid attaching files, web pages and document collections
# and reports honestly whether this Open WebUI version also blocks a normal user's upload on the server.
#
# A temporary normal user (random e-mail and password, never printed) is created inside the container and
# deleted at the end, together with anything it uploaded. Admin accounts are not touched.
# Run from the repository root with the stack running:
#     bash tests/openwebui/check_access.sh
set -u
BASE="https://127.0.0.1:3443"
pass=0; fail=0; gaps=0
ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }
gap() { echo "GAP   $1"; gaps=$((gaps + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
TMP=$(mktemp -d); chmod 700 "$TMP"
EMAIL="gforcex-test-$(openssl rand -hex 4)@example.invalid"
openssl rand -base64 24 > "$TMP/pw"

py() { docker compose exec -T open-webui python3 - "$@" 2>/dev/null; }
cleanup() {
  [[ -n "${FILE_ID:-}" && -n "${TOKEN:-}" ]] && curl -sk -X DELETE -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/files/$FILE_ID" >/dev/null
  py "$EMAIL" <<'EOF' >/dev/null
import asyncio, sys
from open_webui.models.auths import Auths
from open_webui.models.users import Users
async def main():
    u = await Users.get_user_by_email(sys.argv[1])
    if u: await Auths.delete_auth_by_id(u.id)
asyncio.run(main())
EOF
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== Sign-up and CORS =="
signup=$(curl -sk "$BASE/api/config" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("features",{}).get("enable_signup"))')
check "public config reports sign-up disabled (enable_signup=$signup)" '[ "$signup" = False ]'
code=$(curl -sk -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d "{\"name\":\"x\",\"email\":\"signup-$EMAIL\",\"password\":\"$(cat "$TMP/pw")\"}" "$BASE/api/v1/auths/signup")
check "self sign-up is refused (HTTP $code)" '[ "$code" = 403 ] || [ "$code" = 401 ]'
evil=$(curl -sk -D - -o /dev/null -H 'Origin: https://evil.example' "$BASE/api/config" | tr -d '\r' | grep -i '^access-control-allow-origin:' | cut -d' ' -f2)
check "CORS does not allow other websites (evil.example got: '${evil:-none}')" '[ -z "$evil" ]'
own=$(curl -sk -D - -o /dev/null -H 'Origin: https://127.0.0.1:3443' "$BASE/api/config" | tr -d '\r' | grep -i '^access-control-allow-origin:' | cut -d' ' -f2)
check "CORS allows our own HTTPS origin ($own)" '[ "$own" = "https://127.0.0.1:3443" ]'

echo "== Normal user permissions (temporary test user) =="
py "$EMAIL" "$(cat "$TMP/pw")" <<'EOF'
import asyncio, sys
from open_webui.models.auths import Auths
from open_webui.utils.auth import get_password_hash
async def main():
    u = await Auths.insert_new_auth(email=sys.argv[1], password=await get_password_hash(sys.argv[2]),
                                    name="G-ForceX access test", role="user")
    print("created" if u else "not created")
asyncio.run(main())
EOF
TOKEN=$(curl -sk -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$(cat "$TMP/pw")\"}" \
  "$BASE/api/v1/auths/signin" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
role=$(curl -sk -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/auths/" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("role"))' 2>/dev/null)
check "temporary normal user signed in (role: $role)" '[ -n "$TOKEN" ] && [ "$role" = user ]'
perms=$(curl -sk -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/users/permissions")
get() { echo "$perms" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1',{}).get('$2'))" 2>/dev/null; }
check "normal user may NOT attach files to chats (chat.file_upload=$(get chat file_upload))" '[ "$(get chat file_upload)" = False ]'
check "normal user may NOT add web pages as documents (chat.web_upload=$(get chat web_upload))" '[ "$(get chat web_upload)" = False ]'
check "normal user may NOT create document collections (workspace.knowledge=$(get workspace knowledge))" '[ "$(get workspace knowledge)" = False ]'

echo "== Server-side upload check (honest result) =="
resp=$(curl -sk -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" -F "file=@unapproved_policy.txt" "$BASE/api/v1/files/?process=false")
up_code=$(echo "$resp" | tail -1)
FILE_ID=$(echo "$resp" | sed '$d' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
if [[ "$up_code" =~ ^(401|403)$ ]]; then
  ok "the server refuses a normal user's direct upload (HTTP $up_code)"
else
  gap "the server still ACCEPTS a normal user's direct API upload (HTTP $up_code); the permission only hides the button in this Open WebUI version. Uploaded test file deleted."
fi

echo "== Result: $pass passed, $fail failed, $gaps known gap(s) =="
[[ $fail -eq 0 ]]
