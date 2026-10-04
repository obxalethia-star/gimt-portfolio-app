"""LangServe API for the Quant Hedgefund n8n workflow.

n8n builds the prompts (from the Supabase agent_skills table) and calls this server instead of a
hosted model. Inference runs on Ollama on the same server, so there are no per-token costs.
install_local_ai.sh runs it next to n8n, reachable only from the server itself and n8n's containers.

POST /analyst/invoke   (header: X-API-Key)
    {"input": {"system": "...", "prompt": "...", "image_b64": null, "image_mime": "image/jpeg"}}
 -> {"output": "...", "metadata": {...}}

GET /health            (no key) Ollama reachability and which configured models are pulled.
"""

import os
import secrets
from typing import Optional

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnableConfig, RunnableLambda
from langchain_ollama import ChatOllama
from langserve import add_routes
from pydantic import BaseModel, Field

load_dotenv()

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://127.0.0.1:11434")
# qhf-text / qhf-vision are created by install_local_ai.sh from the base models, with thread and context settings.
TEXT_MODEL = os.getenv("TEXT_MODEL", "qhf-text")
VISION_MODEL = os.getenv("VISION_MODEL", "qhf-vision")
# Ollama silently truncates prompts longer than the context window; the portfolio prompts are ~5k tokens.
NUM_CTX = int(os.getenv("NUM_CTX", "8192"))
TEMPERATURE = float(os.getenv("TEMPERATURE", "0.3"))
KEEP_ALIVE = os.getenv("KEEP_ALIVE", "10m")
# Match the CPU limit given to Ollama; more threads than cores makes CPU inference much slower.
NUM_THREAD = int(os.getenv("NUM_THREAD", "0")) or None
API_KEY = os.getenv("QHF_API_KEY", "")

if len(API_KEY) < 24:
    raise RuntimeError("Set QHF_API_KEY (at least 24 characters) in .env before starting the server.")


class AnalystInput(BaseModel):
    system: str = Field(..., description="System prompt assembled from the agent_skills table")
    prompt: str = Field(..., description="User prompt: market data, headlines or portfolio metrics")
    image_b64: Optional[str] = Field(None, description="Base64 chart screenshot (chart mode only)")
    image_mime: str = Field("image/jpeg", description="MIME type of image_b64")


def _model(name: str) -> ChatOllama:
    return ChatOllama(
        base_url=OLLAMA_BASE_URL,
        model=name,
        temperature=TEMPERATURE,
        num_ctx=NUM_CTX,
        num_thread=NUM_THREAD,
        keep_alive=KEEP_ALIVE,
    )


text_chain = _model(TEXT_MODEL) | StrOutputParser()
vision_chain = _model(VISION_MODEL) | StrOutputParser()


def analyse(payload, config: RunnableConfig) -> str:
    data = payload.model_dump() if isinstance(payload, BaseModel) else dict(payload)
    system = SystemMessage(content=data["system"])
    image = data.get("image_b64")
    if image:
        human = HumanMessage(
            content=[
                {"type": "text", "text": data["prompt"]},
                {"type": "image_url", "image_url": f"data:{data.get('image_mime') or 'image/jpeg'};base64,{image}"},
            ]
        )
        return vision_chain.invoke([system, human], config)
    return text_chain.invoke([system, HumanMessage(content=data["prompt"])], config)


analyst = RunnableLambda(analyse).with_types(input_type=AnalystInput, output_type=str)

app = FastAPI(title="QHF LangChain server", version="1.0.0")


@app.middleware("http")
async def require_api_key(request: Request, call_next):
    if request.url.path == "/health":
        return await call_next(request)
    supplied = request.headers.get("x-api-key", "")
    if not secrets.compare_digest(supplied, API_KEY):
        return JSONResponse({"detail": "Missing or invalid X-API-Key header."}, status_code=401)
    return await call_next(request)


def _tagged(name: str) -> str:
    """Ollama lists untagged models as name:latest."""
    return name if ":" in name else f"{name}:latest"


@app.get("/health")
async def health():
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            tags = (await client.get(f"{OLLAMA_BASE_URL}/api/tags")).json()
        pulled = {_tagged(m["name"]) for m in tags.get("models", [])}
    except Exception as exc:  # Ollama down or unreachable
        return JSONResponse({"ok": False, "ollama": str(exc)}, status_code=503)
    models = {name: _tagged(name) in pulled for name in (TEXT_MODEL, VISION_MODEL)}
    return {"ok": all(models.values()), "models": models}


add_routes(
    app,
    analyst,
    path="/analyst",
    enabled_endpoints=["invoke", "batch", "input_schema", "output_schema", "config_schema"],
)
