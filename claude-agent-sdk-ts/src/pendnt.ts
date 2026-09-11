// Thin pendnt REST client used by demo.ts's canUseTool implementation.
// Mirrors /root/work/plugin/lib/client.mjs (the Claude Code plugin's own helper) and
// the shapes documented in /root/work/app/README.md's "API reference" → "Requests".

export const PENDNT_URL = (process.env.PENDNT_URL ?? "https://api.pendnt.dev").replace(/\/+$/, "");
export const PENDNT_API_KEY = process.env.PENDNT_API_KEY ?? "";

export type RequestStatus = "pending" | "approved" | "denied" | "answered" | "expired" | "cancelled";

export interface PendntRequest {
  id: string;
  kind: "approval" | "question" | "notification";
  title: string;
  details?: string | null;
  options?: string[] | null;
  status: RequestStatus;
  answer?: string | null;
  answered_by?: string | null;
  created_at: string;
  expires_at?: string | null;
  answered_at?: string | null;
  hint?: string;
}

class PendntApiError extends Error {
  status: number;
  body: unknown;
  constructor(status: number, body: unknown, message: string) {
    super(message);
    this.name = "PendntApiError";
    this.status = status;
    this.body = body;
  }
}

async function call<T>(
  method: string,
  path: string,
  body?: unknown,
  { timeoutMs = 30_000 }: { timeoutMs?: number } = {},
): Promise<T> {
  if (!PENDNT_API_KEY) {
    throw new Error("PENDNT_API_KEY is not set");
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${PENDNT_URL}${path}`, {
      method,
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${PENDNT_API_KEY}`,
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
    const text = await res.text();
    let json: unknown;
    try {
      json = text ? JSON.parse(text) : {};
    } catch {
      json = { raw: text };
    }
    if (!res.ok) {
      const message =
        (json && typeof json === "object" && "message" in json && typeof (json as { message?: unknown }).message === "string"
          ? (json as { message: string }).message
          : undefined) ?? `${method} ${path} failed: HTTP ${res.status}`;
      throw new PendntApiError(res.status, json, message);
    }
    return json as T;
  } finally {
    clearTimeout(timer);
  }
}

/** POST /v1/requests — kind defaults server-side to "approval". */
export function createRequest(input: {
  kind?: "approval" | "question" | "notification";
  title: string;
  details?: string;
  options?: string[];
  timeout_s?: number;
  wait_s?: number;
}): Promise<PendntRequest> {
  return call<PendntRequest>("POST", "/v1/requests", input);
}

/** GET /v1/requests/:id?wait_s=N — wait_s is clamped to 0-25 server-side. */
export function getRequest(id: string, waitS: number): Promise<PendntRequest> {
  return call<PendntRequest>("GET", `/v1/requests/${encodeURIComponent(id)}?wait_s=${waitS}`, undefined, {
    timeoutMs: (waitS + 10) * 1000,
  });
}

/** POST /v1/notify — fire-and-forget. */
export function notify(message: string, level: "info" | "warning" | "error" = "info"): Promise<{ id: string; status: "answered" }> {
  return call("POST", "/v1/notify", { message, level });
}

/**
 * Create an approval request and long-poll it to a terminal state, honoring a total
 * wall-clock budget (`totalTimeoutS`) built out of repeated 25s server-clamped polls —
 * same pattern as the plugin's PermissionRequest hook
 * (/root/work/plugin/hooks/permission-request.mjs) and examples/curl/approve.sh.
 */
export async function requestApprovalAndWait(
  title: string,
  details: string,
  totalTimeoutS: number,
  signal?: AbortSignal,
): Promise<PendntRequest> {
  const POLL_WAIT_S = 25; // server-enforced max per call
  const startedAt = Date.now();

  let row = await createRequest({
    kind: "approval",
    title,
    details,
    wait_s: POLL_WAIT_S,
    timeout_s: totalTimeoutS,
  });

  while (row.status === "pending") {
    if (signal?.aborted) throw new Error("aborted");
    const elapsedS = (Date.now() - startedAt) / 1000;
    if (elapsedS >= totalTimeoutS) break;
    const waitS = Math.max(1, Math.min(POLL_WAIT_S, Math.ceil(totalTimeoutS - elapsedS)));
    row = await getRequest(row.id, waitS);
  }
  return row;
}

/** True if a resolved request row should be treated as "approved". */
export function isApproved(row: PendntRequest): boolean {
  if (row.status === "approved") return true;
  if (row.status === "answered") {
    // The operator answer page always shows a free-text box, even for approval-kind
    // requests — treat a yes/allow/approve-style answer as approval, fail closed
    // otherwise. Same convention as the Claude Code plugin's PermissionRequest hook.
    const text = (row.answer ?? "").trim().toLowerCase();
    return /^(yes|y|allow|approve|approved|ok|okay)\b/.test(text);
  }
  return false;
}
