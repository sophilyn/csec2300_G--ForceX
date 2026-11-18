"""Ask the agent one question from the command line.

Usage (inside the container):
    python -m gforcex_agent.run_query "What is the fictional lab network named?"
Prints the final answer and the tools the agent called (names only).
"""
import asyncio
import json
import logging
import sys
import time
import uuid

from google.adk.runners import InMemoryRunner
from google.genai import types

from .agent import root_agent
from .audit import audit, reset_query_id, set_query_id
from .retry import looks_like_printed_tool_call

APP = "gforcex"
LOG = logging.getLogger("gforcex.run_query")


async def ask(question: str, source: str = "cli") -> dict:
    """Asks once; retries one time in a fresh session if the model printed its tool call.

    Every query is audited: question received, retry, and outcome (answer length only).
    """
    query_id = uuid.uuid4().hex[:12]
    started = time.monotonic()
    token = set_query_id(query_id)  # document-tool events below get this query_id too
    try:
        return await _ask_audited(question, source, query_id, started)
    finally:
        reset_query_id(token)


async def _ask_audited(question: str, source: str, query_id: str, started: float) -> dict:
    audit("query_received", query_id=query_id, source=source, question=question,
          question_chars=len(question))
    try:
        result = await _ask_once(question)
        result["retried"] = False
        if looks_like_printed_tool_call(result["answer"], result["tools_called"]):
            LOG.warning("model printed a tool call as text; retrying once")
            audit("query_retried", query_id=query_id, reason="tool call printed as text")
            result = await _ask_once(question)
            result["retried"] = True
    except Exception as exc:
        audit("query_failed", query_id=query_id, error=type(exc).__name__,
              duration_ms=int((time.monotonic() - started) * 1000))
        raise
    audit("query_completed", query_id=query_id, tools_called=result["tools_called"],
          retried=result["retried"], answer_chars=len(result["answer"]),
          duration_ms=int((time.monotonic() - started) * 1000))
    return result


async def _ask_once(question: str) -> dict:
    runner = InMemoryRunner(agent=root_agent, app_name=APP)
    session = await runner.session_service.create_session(app_name=APP, user_id="cli")
    message = types.Content(role="user", parts=[types.Part(text=question)])
    tools_called, answer = [], ""
    async for event in runner.run_async(user_id="cli", session_id=session.id, new_message=message):
        for call in event.get_function_calls() or []:
            tools_called.append(call.name)
        if event.is_final_response() and event.content and event.content.parts:
            answer = "".join(p.text or "" for p in event.content.parts)
    return {"answer": answer, "tools_called": tools_called}


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    if len(sys.argv) != 2 or not 0 < len(sys.argv[1]) <= 4000:
        sys.exit('usage: python -m gforcex_agent.run_query "question (1-4000 chars)"')
    print(json.dumps(asyncio.run(ask(sys.argv[1])), indent=2))


if __name__ == "__main__":
    main()
