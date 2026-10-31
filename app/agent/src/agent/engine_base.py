"""Shared result type and interface for the two interchangeable engines --
this layer never touches identity or credentials directly, just the
chat-turn contract both engines produce.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


@dataclass
class AgentTurnResult:
    reply: str
    events: list[dict] = field(default_factory=list)
    requires_approval: bool = False
    approval_id: str | None = None
    approval_text: str | None = None


class Engine(Protocol):
    def handle_message(self, customer_id: int, message: str, thread_id: str) -> AgentTurnResult: ...

    def handle_resume(self, thread_id: str, approved_by: str) -> AgentTurnResult: ...
