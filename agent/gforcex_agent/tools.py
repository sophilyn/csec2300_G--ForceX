"""Allowlisted document tools for the G-ForceX ADK agent.

Pure Python (standard library only) so the security checks can be unit-tested
without installing ADK. Security controls enforced here:
  * Only files inside APPROVED_DOCS_DIR (mounted read-only in Docker).
  * Only .txt/.md files, by plain file name (no folders, no path tricks).
  * Paths are fully resolved, so symlinks/".." that escape the folder are refused.
  * Size cap so one document cannot flood the model context.
Document text is returned wrapped in <untrusted_document> tags so the model
treats it as data, not instructions. This reduces, but does not eliminate,
prompt-injection risk.
"""
import logging
import os
import re
from pathlib import Path

LOG = logging.getLogger("gforcex.tools")

ALLOWED_SUFFIXES = (".txt", ".md")
MAX_BYTES = 64 * 1024
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")


def _approved_dir() -> Path:
    return Path(os.environ.get("APPROVED_DOCS_DIR", "/data/approved")).resolve()


def _resolve(name: str) -> Path:
    if not isinstance(name, str) or not _NAME_RE.fullmatch(name) or ".." in name:
        raise ValueError("Invalid document name")
    base = _approved_dir()
    path = (base / name).resolve()
    if path.parent != base or path.suffix.lower() not in ALLOWED_SUFFIXES or not path.is_file():
        raise ValueError("Document is not on the approved list")
    if path.stat().st_size > MAX_BYTES:
        raise ValueError("Document exceeds 64 KiB limit")
    return path


def list_approved_documents() -> dict:
    """Lists the documents the assistant is approved to read.

    Returns:
        dict: {"status": "success", "documents": [file names]}.
    """
    base = _approved_dir()
    docs = []
    if base.is_dir():
        for item in sorted(base.iterdir()):
            try:
                docs.append(_resolve(item.name).name)
            except ValueError:
                continue
    LOG.info("list_approved_documents count=%d", len(docs))
    return {"status": "success", "documents": docs}


MAX_TOTAL_BYTES = 128 * 1024


def get_approved_documents() -> dict:
    """Returns the full text of every approved document. Call this before answering.

    Returns:
        dict: {"status": "success", "documents": "<untrusted_document ...>...</untrusted_document>..."}
    """
    parts, total = [], 0
    for name in list_approved_documents()["documents"]:
        result = read_approved_document(name)
        if result["status"] != "success":
            continue
        total += len(result["content"])
        if total > MAX_TOTAL_BYTES:
            LOG.warning("get_approved_documents truncated at total cap")
            break
        parts.append(result["content"])
    LOG.info("get_approved_documents count=%d", len(parts))
    return {"status": "success", "documents": "\n\n".join(parts) or "No approved documents."}


def read_approved_document(name: str) -> dict:
    """Reads one approved document by its file name.

    Args:
        name: File name exactly as returned by list_approved_documents.

    Returns:
        dict: {"status": "success", "content": text} or
              {"status": "error", "error_message": reason}.
    """
    try:
        path = _resolve(name)
        text = path.read_text(encoding="utf-8")
    except (ValueError, OSError, UnicodeDecodeError) as exc:
        # Log the refusal reason and a truncated name only; never document contents.
        LOG.warning("read_approved_document refused name=%r reason=%s", str(name)[:100], exc)
        return {"status": "error", "error_message": "Document is not available to the assistant."}
    LOG.info("read_approved_document ok name=%s bytes=%d", path.name, len(text))
    return {
        "status": "success",
        "content": f"<untrusted_document name=\"{path.name}\">\n{text}\n</untrusted_document>",
    }
