"""Detects when a small local model prints a tool call as text instead of calling it.

Standard library only so it can be unit-tested without ADK.
"""
import re

_TOOL_TEXT_RE = re.compile(r'["\']?name["\']?\s*:\s*["\']?get_approved_documents', re.IGNORECASE)


def looks_like_printed_tool_call(answer: str, tools_called: list) -> bool:
    """True when no tool ran and the answer text is just a JSON-ish tool call."""
    if tools_called or not answer:
        return False
    text = answer.strip()
    return text.startswith("{") and bool(_TOOL_TEXT_RE.search(text))
