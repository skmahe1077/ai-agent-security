"""A regex-based stand-in for the LangChain agent -- ported from the Vault
talk unchanged in spirit (same regex intent classifier, same pending/resume
state machine), adapted to call `session.*` directly instead of a separate
`actions` module (mahi-tools owns that logic now; the agent's session IS
the action interface -- see session.py). Also adds a `scale_deployment`
intent so the gateway is visibly guarding a real Kubernetes operation, not
just application logic.
"""
from __future__ import annotations

import re

import approval
from config import Settings
from engine_base import AgentTurnResult

_REFUND_RE = re.compile(r"refund.*?#?\s*(\d{3,6})", re.IGNORECASE)
_ORDER_RE = re.compile(
    r"(?:order|status|look ?up|where is|find|track(?:ing)?|when will|has.*shipped)"
    r".*?#?\s*(\d{3,6})",
    re.IGNORECASE,
)
_CUSTOMER_RE = re.compile(r"customer\s*#?\s*(\d{1,6})", re.IGNORECASE)
_PII_HINT_RE = re.compile(r"phone|email|contact|address|pii", re.IGNORECASE)
_SCALE_RE = re.compile(r"scale.*?(?:to\s*)?(\d{1,3})\s*(?:replicas?|pods?|instances?)?", re.IGNORECASE)
_SCALE_INTENT_RE = re.compile(r"\b(?:scale|slow|busy|more capacity|more traffic)\b", re.IGNORECASE)

_REFUND_INTENT_RE = re.compile(r"\brefund\b", re.IGNORECASE)
_ORDER_INTENT_RE = re.compile(r"\b(?:order|status|track(?:ing)?)\b", re.IGNORECASE)
_BARE_NUMBER_RE = re.compile(r"#?\s*(\d{3,6})")

_GREETING_RE = re.compile(r"^\s*(?:hi|hello|hey|good (?:morning|afternoon|evening))\b", re.IGNORECASE)
_THANKS_RE = re.compile(r"\b(?:thanks|thank you|cheers|appreciate it)\b", re.IGNORECASE)
_FAREWELL_RE = re.compile(r"^\s*(?:bye|goodbye|see ya|that'?s all|that is all)\b", re.IGNORECASE)
_HELP_RE = re.compile(r"\b(?:help|what can you do|how does this work)\b", re.IGNORECASE)

_GREETING_REPLY = (
    "Hi, I'm the Mahi Stores support agent -- I can check an order's status "
    "(\"where's order #1042\") or process a refund (\"refund order #1042\")."
)
_HELP_REPLY = (
    "I can look up an order's status (\"track order #1042\"), process a refund "
    "(\"refund order #1042\"), or scale the storefront if it's under load "
    "(\"scale the storefront to 4 replicas\")."
)
_FALLBACK_REPLY = (
    "I didn't catch an order number in that. Try \"status of order #1042\" or "
    "\"refund order #1042\" -- or just say hi!"
)


class DeterministicEngine:
    def __init__(self, settings: Settings, session):
        self.settings = settings
        self.session = session
        self.enforce_ownership = settings.agent_mode == "secure"
        self._pending: dict[str, dict] = {}
        self._pending_intent: dict[str, str] = {}

    def handle_message(self, customer_id: int, message: str, thread_id: str) -> AgentTurnResult:
        self.session.begin_turn()
        pending_kind = self._pending_intent.pop(thread_id, None)
        if pending_kind:
            m = _REFUND_RE.search(message) or _ORDER_RE.search(message) or _BARE_NUMBER_RE.search(message)
            if m:
                order_id = int(m.group(1))
                if pending_kind == "refund":
                    return self._start_refund(order_id, message, customer_id, thread_id)
                reply, events = self.session.lookup_order(order_id, customer_id, self.enforce_ownership)
                return AgentTurnResult(reply=reply, events=events)
            self._pending_intent[thread_id] = pending_kind
            return AgentTurnResult(reply="I still need an order number -- something like \"#1042\".", events=[])

        m = _REFUND_RE.search(message)
        if m:
            return self._start_refund(int(m.group(1)), message, customer_id, thread_id)

        m = _CUSTOMER_RE.search(message)
        if m and _PII_HINT_RE.search(message):
            reply, events = self.session.lookup_customer_pii(int(m.group(1)), self.settings.agent_name)
            return AgentTurnResult(reply=reply, events=events)

        m = _ORDER_RE.search(message)
        if m:
            reply, events = self.session.lookup_order(int(m.group(1)), customer_id, self.enforce_ownership)
            return AgentTurnResult(reply=reply, events=events)

        m = _SCALE_RE.search(message)
        if m:
            return self._start_scale(int(m.group(1)), thread_id)

        if _REFUND_INTENT_RE.search(message):
            self._pending_intent[thread_id] = "refund"
            return AgentTurnResult(reply="Sure -- which order number would you like refunded?", events=[])
        if _ORDER_INTENT_RE.search(message):
            self._pending_intent[thread_id] = "lookup"
            return AgentTurnResult(reply="Sure -- which order number would you like me to check?", events=[])
        if _SCALE_INTENT_RE.search(message):
            return AgentTurnResult(reply="Sure -- how many replicas would you like?", events=[])

        if _GREETING_RE.search(message):
            return AgentTurnResult(reply=_GREETING_REPLY, events=[])
        if _FAREWELL_RE.search(message):
            return AgentTurnResult(reply="Take care -- come back any time you need an order looked into.", events=[])
        if _THANKS_RE.search(message):
            return AgentTurnResult(reply="You're welcome -- anything else I can look into?", events=[])
        if _HELP_RE.search(message):
            return AgentTurnResult(reply=_HELP_REPLY, events=[])

        return AgentTurnResult(reply=_FALLBACK_REPLY, events=[])

    def _start_refund(self, order_id: int, message: str, customer_id: int, thread_id: str) -> AgentTurnResult:
        reply, events, requires_approval, amount = self.session.issue_refund(
            order_id, message, customer_id, self.enforce_ownership, issued_by=self.settings.agent_name,
        )
        if requires_approval:
            correlation_id = approval.new_correlation_id()
            self._pending[thread_id] = {
                "kind": "refund", "order_id": order_id, "reason": message,
                "customer_id": customer_id, "correlation_id": correlation_id,
            }
            text = (
                f"A refund of £{(amount or 0)/100:.2f} for order #{order_id} exceeds the "
                f"£{self.settings.refund_approval_threshold_pence/100:.2f} auto-approval limit "
                f"and needs a human to sign off."
            )
            return AgentTurnResult(
                reply=text,
                events=events + [{
                    "type": "approval_requested", "approval_id": correlation_id, "amount_pence": amount,
                    "message": f"refund of £{(amount or 0)/100:.2f} for order #{order_id} is pending human approval",
                }],
                requires_approval=True, approval_id=correlation_id, approval_text=text,
            )
        return AgentTurnResult(reply=reply, events=events)

    def _start_scale(self, replicas: int, thread_id: str) -> AgentTurnResult:
        reply, events, requires_approval = self.session.scale_deployment(replicas)
        if requires_approval:
            correlation_id = approval.new_correlation_id()
            self._pending[thread_id] = {"kind": "scale", "replicas": replicas, "correlation_id": correlation_id}
            text = f"Scaling to {replicas} replicas is above what I'll do on my own -- needs a human to sign off."
            return AgentTurnResult(
                reply=text,
                events=events + [{
                    "type": "approval_requested", "approval_id": correlation_id, "replicas": replicas,
                    "message": f"scale to {replicas} replicas is pending human approval",
                }],
                requires_approval=True, approval_id=correlation_id, approval_text=text,
            )
        return AgentTurnResult(reply=reply, events=events)

    def handle_resume(self, thread_id: str, approved_by: str) -> AgentTurnResult:
        self.session.begin_turn()
        pending = self._pending.pop(thread_id, None)
        if pending is None:
            return AgentTurnResult(reply="There's nothing awaiting approval.", events=[])

        if pending["kind"] == "scale":
            events = [{
                "type": "approval_granted", "approval_id": pending["correlation_id"], "approved_by": approved_by,
                "message": f"{approved_by} approved scaling to {pending['replicas']} replicas",
            }]
            reply, action_events, _ = self.session.scale_deployment(pending["replicas"])
            return AgentTurnResult(reply=reply, events=events + action_events)

        events = [{
            "type": "approval_granted", "approval_id": pending["correlation_id"], "approved_by": approved_by,
            "message": f"{approved_by} approved refund for order #{pending['order_id']}",
        }]
        reply, action_events, _, _ = self.session.issue_refund(
            pending["order_id"], pending["reason"], pending["customer_id"], self.enforce_ownership,
            issued_by=self.settings.agent_name, approved_by=approved_by, correlation_id=pending["correlation_id"],
        )
        return AgentTurnResult(reply=reply, events=events + action_events)
