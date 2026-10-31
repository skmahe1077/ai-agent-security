"""Human-intent plumbing: a plain correlation id minted when an action
pauses for approval, threaded through the chat -> approval -> resume
round-trip.
"""
from __future__ import annotations

import uuid


def new_correlation_id() -> str:
    return str(uuid.uuid4())
