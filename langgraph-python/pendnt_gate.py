"""Standalone pendnt REST client for the LangGraph human-approval node.

Deliberately duplicated (not imported) from ../claude-agent-sdk-python/pendnt.py so
this example directory has no cross-directory import and can be copied on its own.
Stdlib only. See /root/work/app/README.md's "API reference" -> "Requests" for the
POST /v1/requests / GET /v1/requests/:id?wait_s=N shapes this wraps.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Optional
from urllib.parse import quote

PENDNT_URL = os.environ.get("PENDNT_URL", "https://api.pendnt.dev").rstrip("/")
PENDNT_API_KEY = os.environ.get("PENDNT_API_KEY", "")

POLL_WAIT_S = 25  # server clamps wait_s to 0-25 regardless of what's sent
_APPROVE_RE = re.compile(r"^(yes|y|allow|approve|approved|ok|okay)\b", re.IGNORECASE)


@dataclass
class PendntRequest:
    id: str
    kind: str
    title: str
    status: str
    details: Optional[str] = None
    answer: Optional[str] = None
    created_at: Optional[str] = None

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "PendntRequest":
        known = {f for f in cls.__dataclass_fields__}
        return cls(**{k: v for k, v in data.items() if k in known})


def _call(method: str, path: str, body: Optional[dict[str, Any]] = None, timeout_s: float = 30.0) -> dict[str, Any]:
    if not PENDNT_API_KEY:
        raise RuntimeError("PENDNT_API_KEY is not set")
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        f"{PENDNT_URL}{path}",
        data=data,
        method=method,
        headers={"content-type": "application/json", "authorization": f"Bearer {PENDNT_API_KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            text = resp.read().decode("utf-8")
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {path} failed: HTTP {e.code}: {text}") from e


def request_approval_and_wait(title: str, details: str, total_timeout_s: float) -> PendntRequest:
    """Create a pendnt approval request and long-poll it to a terminal state.

    This is the "interrupt()-style" human gate: the graph node calls this and blocks
    (like LangGraph's own `interrupt()` would pause a run for
    resumption-via-checkpointer) until a human answers via the pendnt dashboard/email/
    Telegram, or `total_timeout_s` elapses. Implemented as a plain poll loop rather
    than LangGraph's native interrupt/Command(resume=...) machinery, to keep this
    example runnable without wiring up a checkpointer.
    """
    started_at = time.monotonic()
    row = PendntRequest.from_json(
        _call(
            "POST",
            "/v1/requests",
            {"kind": "approval", "title": title, "details": details, "wait_s": POLL_WAIT_S, "timeout_s": int(total_timeout_s)},
            timeout_s=POLL_WAIT_S + 10,
        )
    )

    while row.status == "pending":
        elapsed_s = time.monotonic() - started_at
        if elapsed_s >= total_timeout_s:
            break
        wait_s = max(1, min(POLL_WAIT_S, int(total_timeout_s - elapsed_s) + 1))
        row = PendntRequest.from_json(
            _call("GET", f"/v1/requests/{quote(row.id, safe='')}?wait_s={wait_s}", timeout_s=wait_s + 10)
        )

    return row


def is_approved(row: PendntRequest) -> bool:
    if row.status == "approved":
        return True
    if row.status == "answered":
        return bool(_APPROVE_RE.match((row.answer or "").strip()))
    return False
