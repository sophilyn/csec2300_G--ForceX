# Open WebUI approved-documents guard (User Story 3, with Story 4 logging)

**Type:** Preventive + Detective · **SY0-701:** 4.0 Security Operations · **Issues:** [#11](https://github.com/sophilyn/csec2300_G--ForceX/issues/11), [#12](https://github.com/sophilyn/csec2300_G--ForceX/issues/12), [#14](https://github.com/sophilyn/csec2300_G--ForceX/issues/14)

## Why
[openwebui-access.md](openwebui-access.md) leaves two known gaps in Open WebUI v0.12.5:
- a signed-in normal user can still **upload a file through the API** (the permission only hides the button);
- **admins** can use the raw Ollama models and attach any file, including `unapproved_policy.txt`.

In manual testing (#12) the model read the attached unapproved policy and repeated `Maple-739`. One reply also
did not clearly refuse. A system prompt alone asks the model to behave. It does not force it.

## What it does: `openwebui/functions/approved_docs_guard.py`
A **global Filter Function**. It runs on every chat, for every model and every user, admins included.

| Stage | Action |
|---|---|
| `inlet` (before the model) | Removes attached files that are not approved, and knowledge collections whose ID is not allowed, from both `files` and `metadata.files`. Adds the security rules as the first system message on **every turn**, so a long chat cannot push them out of the context window. If a file was removed, it also tells the model that file is not approved. **If the latest question asks for the code or the policy** (matches `refuse_request_patterns`: "project code", "company policy", "unapproved", or the code itself), the question is replaced with an instruction to answer with `refusal_message` only. |
| `stream` (while the reply is typed) | Watches for protected values (default: `Maple-739`, also with any Unicode dash, spaces or markdown between characters, spelled letter by letter, full-width, or as `seven-three-nine`). On a match, the held-back text and the rest of the reply are dropped and **only `refusal_message` is shown**. It holds back the last 80 characters, so a value split across chunks is still caught, and the "the code is…" lead-in is usually dropped too. This also covers what **Read Aloud** speaks. |
| `outlet` (saved message) | Runs the same check on the stored reply. A reply containing a protected value is saved as `refusal_message` only. |
| Audit log | JSONL at `/app/backend/data/audit/approved_docs_guard.jsonl` (on the `webui_data` volume, so it is included in backups). Events: `chat_request`, `unapproved_document_blocked` (file **names** only), `unapproved_request_refused`, `protected_value_redacted` (count only). It never logs document contents, replies, questions, or the protected value. |

**Refusal message** (valve `refusal_message`, editable):
> I can't give out that code. It comes from an unapproved policy document, so I'm not allowed to share it.

Set `refuse_whole_reply` to off to go back to replacing only the value with `[REDACTED: unapproved source]`.

**Approve documents by file ID, not by name.** A name check can be fooled by renaming `unapproved_policy.txt` to `approved_class_notes.txt` and uploading it through the API. Once `approved_file_ids` is set, names are ignored.

The redaction list is **defense in depth** for values we know are secret. The main control is still that
unapproved documents never reach the model (the inlet stage, plus keeping them out of every knowledge collection).

## Install (admin, once)
1. **Admin Panel → Functions → +** → paste `openwebui/functions/approved_docs_guard.py` → Save.
2. Switch it **on**, then use **⋯ → Global** so it applies to every model.
3. In the function's **Valves**:
   - `approved_file_ids`: the ID of the uploaded `approved_class_notes.txt` (Workspace → Knowledge → open the file; the ID is in the URL or in `GET /api/v1/files/`);
   - `allowed_knowledge_ids`: the ID of the approved collection, if you use one;
   - `protected_values`: one value per line that must never be shown (variants are matched automatically); `protected_patterns`: optional extra regexes;
   - `refusal_message`: what the assistant says instead; `refuse_request_patterns`: which questions get the refusal straight away.
4. Make sure `unapproved_policy.txt` is in **no** knowledge collection.

## How to test
Unit tests (no stack needed; also run in CI):
```bash
pip install pydantic
python -m unittest discover -s tests/openwebui -p 'test_*.py' -v
```

Live no-leak check against the running stack. It sends 2 approved questions and 7 attempts to extract the
code: a false admin claim, "ignore instructions", spelling it, base64, role-play and hints. The direct question
and the false admin claim must also get a clear refusal, not just a missing code. Run it once per model:
```powershell
$env:OWUI_API_KEY="sk-..."; $env:OWUI_MODEL="gforcex-agent"
python tests/openwebui/validate_no_leak.py
```
Repeat with a raw model (for example `llama3.2:3b`) and with `$env:OWUI_FILE_ID="<id of uploaded unapproved_policy.txt>"`,
to show that an attached unapproved file is dropped. The results CSV is saved in `tests/openwebui/results/` (gitignored); attach it to #12.
Any leaked value is masked as `[LEAK]` in the CSV.

**Validation loop:** each `FAIL` shows which layer to tighten: knowledge collections, the inlet allowlist, the
redaction patterns, or the rules text. Fix it, re-run, and record the new CSV.

## Evidence
- Unit tests: 17 passed (2026-11-19, local). Version 0.2.0 missed Unicode dashes (`Maple‑739`), letter-by-letter spelling and `seven-three-nine`; fixed in 0.3.0. Version 0.4.0 adds the refusal message.
- Live run on the stack: **not yet recorded.** Add the CSV summary here after the first run.

## Limits
- If an approved document is ever replaced, its file ID changes and the valve must be updated.
- Redaction only catches patterns that are listed. A paraphrase such as "the tree name followed by seven-three-nine" depends on the inlet stage having already kept the document away from the model.
- Admins can switch the function off. Changes to functions appear in Open WebUI's own logs, not in this audit log.
