"""Ask the agent one question from the command line.

Usage (inside the container):
    python -m gforcex_agent.run_query "What is the fictional lab network named?"
Prints the final answer and the tools the agent called (names only).
"""
import asyncio
import json
import logging
import sys

from google.adk.runners import InMemoryRunner
from google.genai import types

from .agent import root_agent
from .retry import looks_like_printed_tool_call

APP = "gforcex"
LOG = logging.getLogger("gforcex.run_query")


async def ask(question: str) -> dict:
    """Asks once; retries one time in a fresh session if the model printed its tool call."""
    result = await _ask_once(question)
    result["retried"] = False
    if looks_like_printed_tool_call(result["answer"], result["tools_called"]):
        LOG.warning("model printed a tool call as text; retrying once")
        result = await _ask_once(question)
        result["retried"] = True
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
