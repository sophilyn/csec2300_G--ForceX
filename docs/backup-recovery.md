# Control 3: Data backup and recovery

**Type:** Corrective · **SY0-701:** 3.0 Security Architecture (resilience and recovery) · **Status:** implemented and tested on 2026-11-17

## Goal (from our control plan)
> Create backups in a separate, protected location and document the recovery process.
> Restore a sample file or configuration from a backup and verify that it works.

The team already backed up and restored sample documents and configuration, using an AES-256 encrypted USB (issue #17).
The remaining work was to **demonstrate full application recovery**. This document covers that.

## What is backed up
| Item | Where it lives | Why |
|---|---|---|
| Open WebUI data: accounts, chats, uploads, settings, vector index, cache | Docker volume `webui_data` | User data |
| Ollama models (about 3.2 GB) | Docker volume `ollama_data` | Recovery without re-downloading (team decision, 2026-11-17) |
| Agent audit log (Control 2) | Docker volume `agent_audit`, when present | Keeps the security record |
| `docker-compose.yml`, `.env` (Open WebUI secret key), `approved_class_notes.txt` | Repository folder | Rebuild the same configuration |

Every Docker volume of the Compose project is found automatically, so new volumes are backed up without changing the script.

## How it is protected
- **One encrypted file** per backup: AES-256-CBC, with the key derived from your passphrase using PBKDF2 (600,000 iterations, random salt). `.env` is only stored inside this encrypted file.
- **Separate, private location:** by default `~/GForceX-Backups`, outside the repository, with folder mode `700` and file mode `600`. Use `--dest` to write straight to a USB drive.
- **Two integrity checks:**
  1. a SHA-256 checksum file next to the backup, which catches corruption before decrypting;
  2. a manifest **inside** the encrypted file with the SHA-256 of every item, which catches tampering even if someone also replaces the outer checksum.
- **Consistent snapshot:** the app is stopped during the backup (about 1–2 minutes) so the database is not mid-write, then restarted automatically.
- **Safe restore:**
  - every check must pass before anything is changed;
  - restoring over the live app requires typing `RESTORE`;
  - `--project NAME` restores into separate volumes for drills.

## How to back up
From the repository root:
```bash
bash scripts/backup.sh
```
It asks for a passphrase (at least 12 characters) twice. **Store the passphrase in a password manager.** Without it the backup cannot be restored.

To write the backup straight to a USB drive:
```bash
bash scripts/backup.sh --dest /Volumes/YOUR_USB/GForceX-Backups
```

## How to recover (full application)
1. Make sure Docker is running and you are in the repository folder (clone it again if the computer was replaced).
2. Run the restore and type your passphrase, then `RESTORE` when asked:
   ```bash
   bash scripts/restore.sh ~/GForceX-Backups/gforcex-backup-YYYYMMDDTHHMMSSZ.tar.enc
   ```
3. If `.env` was lost, copy it back from the `restored-config-…` folder the restore prints:
   ```bash
   cp ~/GForceX-Backups/restored-config-YYYYMMDDTHHMMSSZ/.env .env
   ```
4. Start the app and check it:
   ```bash
   docker compose up -d
   ```
   Then open http://localhost:3000, log in with an existing account, and confirm your chats are there.
5. Delete the `restored-config-…` folder after use, because it holds a plain copy of `.env`.

## How to test (disaster drill)
```bash
bash tests/backup/check_backup_restore.sh
```
The drill only **reads** live data. It restores into separate `gforcex-drill` volumes, then deletes them, its temporary backup, and its throwaway passphrase. It takes about 5–10 minutes.

## Evidence (macOS, Docker 29.7.2, 4.2 GB backup)
Disaster drill: **16 passed, 0 failed**, exit code 0.
```
== 1. Fingerprint live data (app stopped for a consistent snapshot) ==
      agent_audit: 1 files, sha256 2de7eea3f41dbc0a
      ollama_data: 17 files, sha256 ba20c722b4c8a1c4
      webui_data: 145 files, sha256 306d6b9d6039a9b3
      Open WebUI database: users=1 chats=8
== 2. Backup ==
PASS  backup file created in 94s (4.2G)
== 3. Backup is protected ==
PASS  backup file is encrypted (OpenSSL salted AES format)
PASS  backup file and folder are owner-only (600 / 700)
PASS  no readable secret key name or document text inside the file
PASS  SHA-256 checksum file written next to the backup
== 4. Bad restores are refused and change nothing ==
PASS  wrong passphrase is refused (exit 1: FAILED: could not decrypt. Wrong passphrase or damaged file.)
PASS  tampered backup is refused by the checksum (exit 1)
PASS  tampered backup with a forged checksum is still refused (exit 1: ./volumes/ollama_data.tar: FAILED)
PASS  refused restores created no volumes
== 5. Restore into separate drill volumes ==
PASS  agent_audit restored identical: 1 files, sha256 2de7eea3f41dbc0a
PASS  ollama_data restored identical: 17 files, sha256 ba20c722b4c8a1c4
PASS  webui_data restored identical: 145 files, sha256 306d6b9d6039a9b3
PASS  Open WebUI database restored with the same accounts and chats (users=1 chats=8)
PASS  configuration restored (.env matches, compared without printing it)
== 6. The app runs from the restored data ==
PASS  restored Open WebUI starts and is healthy (HTTP 200 on drill port 3901)
PASS  restored Ollama has the model without downloading (models: llama3.2:3b llama3.2:1b )
== Result: 16 passed, 0 failed ==
```
A second real backup was made **while the app was running**. It stopped the 3 services, backed up, and restarted all 3. Its manifest recorded the app versions:
```
images: ghcr.io/open-webui/open-webui:v0.12.5 gforcex-adk-agent:0.1.0 ollama/ollama:0.40.14
```
(The drill ran before a one-line fix that fills in this `images:` line, which was empty in the drill's manifest. Nothing else changed.)

## Limitations
- **Backups are manual.** There is no schedule. Run `scripts/backup.sh` before risky changes and on a regular routine.
- **Old backups are never deleted automatically.** Each is about 4.2 GB, so remove old ones by hand.
- **The passphrase is the single point of failure.** If it is lost, so are the backups. If it is weak, the encryption is weak.
- AES-256-CBC does not authenticate data by itself. Tampering is caught by the SHA-256 manifest inside the encrypted file instead.
- A backup in `~/GForceX-Backups` on the same disk does not survive a disk failure or a stolen laptop. Copy backups to a USB drive or another device (`--dest`).
- The app is down for about 1–2 minutes during each backup.
- The drill and backup are not run in CI, because they need the real Docker volumes and about 9 GB of disk.
