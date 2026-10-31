"""HTTP wrapper around one agent engine.

One image, two running shapes: `AGENT_MODE=insecure` with a StaticDBSession,
or `AGENT_MODE=secure` with a GatewaySession (see session.py). Which
`Engine` implementation answers `/chat` is a separate axis (`AGENT_ENGINE`).

There is no per-request lease to revoke on demand -- revocation of an
agent's database privilege is a Git commit against k8s/cnpg/cluster.yaml's
spec.managed.roles, not an API call this process can make about itself.
`approved_by` alone is the whole approval signal on `/resume`, plumbed
through to mahi-tools as the X-Approved-By header -- see session.py.
"""
from __future__ import annotations

from fastapi import FastAPI
from pydantic import BaseModel

from config import load_settings
from deterministic_engine import DeterministicEngine
from session import build_session

settings = load_settings()
session = build_session(settings)

if settings.agent_engine == "langchain":
    from langchain_engine import LangChainEngine  # heavy import, only when needed

    engine = LangChainEngine(settings, session)
else:
    engine = DeterministicEngine(settings, session)

app = FastAPI(title=f"agent ({settings.agent_mode})")


class ChatRequest(BaseModel):
    customer_id: int
    message: str
    thread_id: str = "demo"


@app.post("/chat")
def chat(req: ChatRequest):
    result = engine.handle_message(req.customer_id, req.message, req.thread_id)
    return {
        "reply": result.reply,
        "events": result.events,
        "requires_approval": result.requires_approval,
        "approval_id": result.approval_id,
        "approval_text": result.approval_text,
    }


class ResumeRequest(BaseModel):
    thread_id: str = "demo"
    approved_by: str


@app.post("/resume")
def resume(req: ResumeRequest):
    result = engine.handle_resume(req.thread_id, req.approved_by)
    return {
        "reply": result.reply,
        "events": result.events,
        "requires_approval": result.requires_approval,
        "approval_id": result.approval_id,
        "approval_text": result.approval_text,
    }


@app.get("/status")
def status():
    return session.status()


@app.get("/healthz")
def healthz():
    return {"ok": True, "mode": settings.agent_mode, "engine": settings.agent_engine}
