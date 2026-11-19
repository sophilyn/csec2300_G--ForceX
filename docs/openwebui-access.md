# Open WebUI access control (Control 4, chat interface)

**Type:** Preventive · **SY0-701:** 4.0 Security Operations (identity and access management) · **Tested:** 2026-11-19

## What triggered this
During manual testing, a team member attached `unapproved_policy.txt` to an Open WebUI chat, and the model
answered with the fictional project code `Maple-739`. This was **not** the ADK agent leaking a file. The user
supplied the file, and Open WebUI let the model read it. But it showed a real gap:
- Open WebUI has **no document allowlist**. Any signed-in user could attach any file.
- CORS accepted **any website** as an origin.

## What changed (`docker-compose.yml`, `open-webui` service)
| Setting | Value | Effect |
|---|---|---|
| `ENABLE_PERSISTENT_CONFIG` | `False` | These settings come from `docker-compose.yml` on every start. Without it, Open WebUI keeps older values from its database and ignores the file. |
| `ENABLE_SIGNUP` | `False` | No self sign-up. The admin creates accounts. |
| `DEFAULT_USER_ROLE` | `pending` | Any new account needs admin approval. |
| `USER_PERMISSIONS_CHAT_FILE_UPLOAD` | `False` | Normal users cannot attach files to chats. |
| `USER_PERMISSIONS_CHAT_WEB_UPLOAD` | `False` | Normal users cannot pull web pages in as documents. |
| `USER_PERMISSIONS_WORKSPACE_KNOWLEDGE_ACCESS` | `False` | Normal users cannot create document collections. |
| `CORS_ALLOW_ORIGIN` | `https://localhost:3443;https://127.0.0.1:3443` | Only our own HTTPS address. Other websites are refused. This also limits the live-chat connection (socket.io). |

**Admins are not limited by user permissions.** Use a normal (non-admin) account for everyday use and demos. Keep the admin account for managing users and approved documents.

## How to test
With the stack running, from the repository root:
```bash
bash tests/openwebui/check_access.sh
```
It creates a temporary normal user (random e-mail and password, never printed), checks what that user can do through the HTTPS proxy, and deletes the user and anything it uploaded.

## Evidence (macOS, Open WebUI v0.12.5, 2026-11-19)
**Before** (previous settings): 5 passed, **3 failed**:
- CORS echoed back `https://evil.example`;
- a normal user had `chat.file_upload=True`;
- a normal user had `chat.web_upload=True`.

**After:** 8 passed, 0 failed, 1 known gap.
```
PASS  public config reports sign-up disabled (enable_signup=False)
PASS  self sign-up is refused (HTTP 403)
PASS  CORS does not allow other websites (evil.example got: 'none')
PASS  CORS allows our own HTTPS origin (https://127.0.0.1:3443)
PASS  temporary normal user signed in (role: user)
PASS  normal user may NOT attach files to chats (chat.file_upload=False)
PASS  normal user may NOT add web pages as documents (chat.web_upload=False)
PASS  normal user may NOT create document collections (workspace.knowledge=False)
GAP   the server still ACCEPTS a normal user's direct API upload (HTTP 200); the permission only hides the button in this Open WebUI version. Uploaded test file deleted.
== Result: 8 passed, 0 failed, 1 known gap(s) ==
```

## Known gap (honest)
In Open WebUI **v0.12.5**, the upload endpoint (`POST /api/v1/files/`) does not check the `chat.file_upload` permission. The permission only hides the upload button.

A signed-in normal user who calls the API directly can still upload a file they already have. The test keeps reporting this as `GAP`, so it is never hidden.

Compensating controls:
- Only admin-created and admin-approved accounts exist (sign-up off, new accounts `pending`).
- The app is reachable only through the HTTPS proxy.
- The **ADK agent** is the path that enforces the document allowlist.

Next steps:
- Re-run this test after upgrading Open WebUI, because newer versions may check the permission on the server.
- Optionally, block `POST /api/v1/files` at the HTTPS proxy. That would also stop admins uploading through the browser.

## Note for LAN sharing
If Open WebUI is shared on a LAN address through a local, uncommitted `docker-compose.override.yml`, add that HTTPS address to `CORS_ALLOW_ORIGIN` **in the override file**. Otherwise the partner's live chat connection is refused. Sharing on the LAN also breaks Control 1's "this computer only" rule, and `tests/network/check_network.sh` reports it as FAIL while sharing is on.
