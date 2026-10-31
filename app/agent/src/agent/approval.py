"""Human-intent plumbing: a correlation id minted when an action pauses for
approval. Ported from the Vault talk, minus the Vault-token-metadata half
of the original (no child token exists to carry it anymore) -- the
remaining piece, a plain correlation id threaded through the chat ->
approval -> resume round-trip, is unchanged.
"""
from __future__ import annotations

import uuid


def new_correlation_id() -> str:
    return str(uuid.uuid4())
