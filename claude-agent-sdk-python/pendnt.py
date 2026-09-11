"""Thin pendnt REST client used by demo.py's can_use_tool implementation.

Mirrors /root/work/plugin/lib/client.mjs (the Claude Code plugin's own helper) and the
shapes documented in /root/work/app/README.md's "API reference" -> "Requests". Uses
only the stdlib (urllib) so this module has zero dependencies beyond the Agent SDK
itself.
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


class PendntApiError(Exception):
    def __init__(self, status: int, body: Any, message: str):
        super().__init__(message)
        self.status = status
        self.body = body


@dataclass
class PendntRequest:
    id: str
    kind: str
    title: str
    status: str
    details: Optional[str] = None
    options: Optional[list[str]] = None
    answer: Optional[str] = None
    answered_by: Optional[str] = None
    created_at: Optional[str] = None
    expires_at: Optional[str] = None
    answered_at: Optional[str] = None
    hint: Optional[str] = None

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "PendntRequest":
        known = {f for f in cls.__dataclass_fields__}
        return cls(**{k: v for k, v in data.items() if k in known})


def _call(method: str, path: str, body: Optional[dict[str, Any]] = None, timeout_s: float = 30.0) -> dict[str, Any]:
    if not PENDNT_API_KEY:
        raise RuntimeError("PENDNT_API_KEY is not set")
    url = f"{PENDNT_URL}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "content-type": "application/json",
            "authorization": f"Bearer {PENDNT_API_KEY}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            text = resp.read().decode("utf-8")
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text) if text else {}
        except json.JSONDecodeError:
            parsed = {"raw": text}
        message = parsed.get("message") if isinstance(parsed, dict) else None
        raise PendntApiError(e.code, parsed, message or f"{method} {path} failed: HTTP {e.code}") from e


def create_request(
    title: str,
    *,
    kind: str = "approval",
    details: str = "",
    options: Optional[list[str]] = None,
    timeout_s: int = 86400,
    wait_s: int = 0,
) -> PendntRequest:
    """POST /v1/requests"""
    body: dict[str, Any] = {"kind": kind, "title": title, "details": details, "timeout_s": timeout_s, "wait_s": wait_s}
    if options is not None:
        body["options"] = options
    return PendntRequest.from_json(_call("POST", "/v1/requests", body, timeout_s=wait_s + 10))


def get_request(request_id: str, wait_s: int = 0) -> PendntRequest:
    """GET /v1/requests/:id?wait_s=N — wait_s is clamped to 0-25 server-side."""
    path = f"/v1/requests/{quote(request_id, safe='')}?wait_s={wait_s}"
    return PendntRequest.from_json(_call("GET", path, timeout_s=wait_s + 10))


def notify(message: str, level: str = "info") -> dict[str, Any]:
    """POST /v1/notify — fire-and-forget."""
    return _call("POST", "/v1/notify", {"message": message, "level": level})


def request_approval_and_wait(title: str, details: str, total_timeout_s: float) -> PendntRequest:
    """Create an approval request and long-poll it to a terminal state, honoring a
    total wall-clock budget built out of repeated 25s server-clamped polls — same
    pattern as the plugin's PermissionRequest hook
    (/root/work/plugin/hooks/permission-request.mjs) and examples/curl/approve.sh.
    """
    started_at = time.monotonic()
    row = create_request(title, details=details, wait_s=POLL_WAIT_S, timeout_s=int(total_timeout_s))

    while row.status == "pending":
        elapsed_s = time.monotonic() - started_at
        if elapsed_s >= total_timeout_s:
            break
        wait_s = max(1, min(POLL_WAIT_S, int(total_timeout_s - elapsed_s) + 1))
        row = get_request(row.id, wait_s=wait_s)

    return row


def is_approved(row: PendntRequest) -> bool:
    """True if a resolved request row should be treated as 'approved'."""
    if row.status == "approved":
        return True
    if row.status == "answered":
        # The operator answer page always shows a free-text box, even for
        # approval-kind requests -- treat a yes/allow/approve-style answer as
        # approval, fail closed otherwise. Same convention as the Claude Code
        # plugin's PermissionRequest hook.
        text = (row.answer or "").strip()
        return bool(_APPROVE_RE.match(text))
    return False
