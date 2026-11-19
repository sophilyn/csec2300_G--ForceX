"""OpenAI-compatible API in front of the G-ForceX ADK agent, so Open WebUI can chat with it.

Open WebUI connects to it as an "OpenAI" connection (base URL http://adk-agent:8000/v1). Every chat is
answered by the same agent and allowlist tool as the command line (run_query.ask), so the chat interface
can only answer from approved documents.

Security:
  * Every request needs "Authorization: Bearer <GFORCEX_AGENT_API_KEY>" (compared in constant time).
    The server refuses to start without a key of at least 32 characters.
  * Only the LAST user message is used as the question, capped at 4000 characters. Earlier turns,
    system prompts and any attached context from the chat are ignored, so they cannot smuggle document
    text past the allowlist.
  * Open WebUI forwards the user's ID and role (ENABLE_FORWARD_USER_INFO_HEADERS); only those two are
    written to the audit log, never the name or e-mail.
  * Reachable only on an internal Docker network shared with Open WebUI (no host port, no internet).
This replaces the unauthenticated "adk api_server" that the container ran before.

Run inside the container:  python -m gforcex_agent.openai_api
"""
import hmac
import json
import os
import time
import uuid

import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

from .audit import audit
from .run_query import ask

MODEL_ID = "gforcex-agent"
MAX_QUESTION_CHARS = 4000
API_KEY = os.environ.get("GFORCEX_AGENT_API_KEY", "")

app = FastAPI(title="G-ForceX agent (OpenAI-compatible)", docs_url=None, redoc_url=None, openapi_url=None)


def _authorize(request: Request) -> None:
    sent = request.headers.get("authorization", "")
    expected = f"Bearer {API_KEY}"
    if not API_KEY or not hmac.compare_digest(sent.encode(), expected.encode()):
        audit("api_auth_failed", path=request.url.path)
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


def _last_user_question(messages) -> str:
    for message in reversed(messages or []):
        if not isinstance(message, dict) or message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, list):  # OpenAI "parts" format: keep only the text parts
            content = " ".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
        if isinstance(content, str) and content.strip():
            return content.strip()[:MAX_QUESTION_CHARS]
    return ""


@app.get("/v1/models")
async def list_models(request: Request):
    _authorize(request)
    return {"object": "list", "data": [{"id": MODEL_ID, "object": "model", "created": 0, "owned_by": "g-forcex"}]}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    _authorize(request)
    try:
        body = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="Body must be JSON")
    if body.get("model") != MODEL_ID:
        raise HTTPException(status_code=404, detail=f"Unknown model; only {MODEL_ID} is available")
    question = _last_user_question(body.get("messages"))
    if not question:
        raise HTTPException(status_code=400, detail="No user question found")

    user_id = request.headers.get("x-openwebui-user-id", "")[:64]
    role = request.headers.get("x-openwebui-user-role", "")[:16]
    audit("openwebui_request", openwebui_user_id=user_id, openwebui_role=role, question_chars=len(question))
    try:
        result = await ask(question, source="openwebui")
        answer = result["answer"] or "Sorry, I could not produce an answer. Please try again."
    except Exception as exc:  # noqa: BLE001 - the error type is audited by ask(); the chat gets a short message
        answer = f"The agent could not answer right now ({type(exc).__name__}). Please try again."

    completion_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    created = int(time.time())
    if body.get("stream"):
        def events():
            chunk = {"id": completion_id, "object": "chat.completion.chunk", "created": created, "model": MODEL_ID,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": answer}, "finish_reason": None}]}
            yield f"data: {json.dumps(chunk)}\n\n"
            done = dict(chunk, choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}])
            yield f"data: {json.dumps(done)}\n\n"
            yield "data: [DONE]\n\n"
        return StreamingResponse(events(), media_type="text/event-stream")
    return JSONResponse({
        "id": completion_id, "object": "chat.completion", "created": created, "model": MODEL_ID,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": answer}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    })


def main() -> None:
    if len(API_KEY) < 32:
        raise SystemExit("GFORCEX_AGENT_API_KEY must be set to at least 32 characters (see .env.example)")
    # Inside the container only; Docker publishes no host port for this service.
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info", access_log=False)  # nosec B104


if __name__ == "__main__":
    main()
