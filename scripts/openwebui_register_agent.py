"""Shares the G-ForceX agent with every Open WebUI user, and nothing else (Control 4).

Open WebUI shows normal users only models that an admin has shared. This creates or updates the model
record for "gforcex-agent" (served by the ADK agent, see agent/gforcex_agent/openai_api.py):
  * readable by all users (access grant user:* read); the raw Ollama models stay unshared,
    so normal users can only chat with the agent and its document allowlist
  * file, image, web search, code and tool capabilities switched off, so nothing can be attached to it

Run once after the stack is up (idempotent, safe to re-run):
    docker compose exec -T open-webui python3 - < scripts/openwebui_register_agent.py
"""
import asyncio

from open_webui.models.access_grants import AccessGrants
from open_webui.models.models import ModelForm, ModelMeta, ModelParams, Models
from open_webui.models.users import Users

MODEL_ID = "gforcex-agent"
FORM = ModelForm(
    id=MODEL_ID,
    base_model_id=None,  # a base model from the agent connection, not a wrapper around another model
    name="G-ForceX Agent (approved documents only)",
    meta=ModelMeta(
        description="Answers only from the approved class notes through the G-ForceX ADK agent.",
        capabilities={"vision": False, "file_upload": False, "web_search": False, "image_generation": False,
                      "code_interpreter": False, "citations": False, "usage": False},
    ),
    params=ModelParams(),
    access_grants=[{"principal_type": "user", "principal_id": "*", "permission": "read"}],
    is_active=True,
)


async def main() -> None:
    admins = [u for u in (await Users.get_users())["users"] if u.role == "admin"]
    if not admins:
        raise SystemExit("No admin account yet: create the first account in Open WebUI, then re-run.")
    if await Models.get_model_by_id(MODEL_ID):
        await Models.update_model_by_id(MODEL_ID, FORM)
        action = "updated"
    else:
        await Models.insert_new_model(FORM, admins[0].id)
        action = "created"
    grants = await AccessGrants.get_grants_by_resource("model", MODEL_ID)
    shared = [m.id for m in await Models.get_all_models()]
    print(f"{MODEL_ID}: {action}; grants={[(g.principal_type, g.principal_id, g.permission) for g in grants]}; "
          f"shared model records={shared}")


asyncio.run(main())
