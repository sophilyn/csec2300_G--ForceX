"""Audit log for the G-ForceX ADK agent (Control 2: Security Monitoring and Audit Logs).

Each event is one JSON object per line (JSON Lines), written to AUDIT_LOG_PATH
(default /var/log/gforcex/audit.jsonl, a Docker volume) and to stderr, so it also shows
in `docker compose logs`. The file rotates at 5 MB and keeps 5 old files.

What is logged: time (UTC), event name, question text (team decision 2026-11-17),
document names and sizes, refusal reasons, tools called, durations, errors.
What is never logged: document contents and model answers (only their lengths).
Text that looks like a password, key or token is replaced with [REDACTED] first.

Standard library only, so it can be unit-tested without ADK or Docker.
"""
import json
import logging
import logging.handlers
import os
import re
import sys
from datetime import datetime, timezone

MAX_FIELD_CHARS = 500
_LOGGER_NAME = "gforcex.audit"

# Secret-looking text. Order matters: "key = value" pairs first, then bare tokens.
_SECRET_PATTERNS = [
    re.compile(r"(?i)\b(password|passwd|pwd|passphrase|secret|token|api[_-]?key|access[_-]?key)\b(\s*[:=]\s*|\s+is\s+)\S+"),
    re.compile(r"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}\b"),          # common API key style
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),               # GitHub tokens
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),                          # AWS access key IDs
    re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),  # JWTs
    re.compile(r"\b[0-9a-fA-F]{32,}\b"),                          # long hex keys (e.g. openssl rand -hex)
]


def redact(text: str) -> str:
    """Replaces secret-looking substrings with [REDACTED]."""
    for pattern in _SECRET_PATTERNS:
        if pattern.groups:  # keep the label ("password=") so the log still says what was hidden
            text = pattern.sub(lambda m: m.group(1) + m.group(2) + "[REDACTED]", text)
        else:
            text = pattern.sub("[REDACTED]", text)
    return text


def _clean(value):
    if isinstance(value, str):
        value = redact(value)
        if len(value) > MAX_FIELD_CHARS:
            value = value[:MAX_FIELD_CHARS] + f"...[truncated {len(value) - MAX_FIELD_CHARS} chars]"
        return value
    if isinstance(value, (list, tuple)):
        return [_clean(v) for v in value]
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    return _clean(str(value))


def _logger() -> logging.Logger:
    logger = logging.getLogger(_LOGGER_NAME)
    if logger.handlers:
        return logger
    logger.setLevel(logging.INFO)
    logger.propagate = False  # do not duplicate through ADK/uvicorn root logging
    stream = logging.StreamHandler(sys.stderr)
    stream.setFormatter(logging.Formatter("AUDIT %(message)s"))
    logger.addHandler(stream)
    path = os.environ.get("AUDIT_LOG_PATH", "/var/log/gforcex/audit.jsonl")
    try:
        handler = logging.handlers.RotatingFileHandler(path, maxBytes=5 * 1024 * 1024, backupCount=5,
                                                       encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(message)s"))
        logger.addHandler(handler)
    except OSError as exc:  # e.g. unit tests or a missing volume: keep stderr logging only
        logger.warning(json.dumps({"event": "audit_file_unavailable", "error": type(exc).__name__}))
    return logger


def audit(event: str, **fields) -> dict:
    """Writes one audit event and returns the record that was written."""
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"), "event": event}
    record.update({k: _clean(v) for k, v in fields.items()})
    # ensure_ascii escapes newlines and control characters, so one event is always one line
    # (user text cannot forge extra log entries).
    _logger().info(json.dumps(record, ensure_ascii=True, sort_keys=False))
    return record
