// pendnt + Claude Agent SDK (TypeScript) — headless query() whose canUseTool
// implements every permission prompt as a pendnt approval request.
//
// Run:
//   PENDNT_API_KEY=aio_... npm run demo -- "delete the file /tmp/scratch.txt"
//
// What happens: the SDK calls canUseTool only when its own permission flow (hooks ->
// deny rules -> ask rules -> mode -> allow rules) falls through to an actual prompt —
// see /root/product/INTEGRATIONS.md §2. When that happens, this script POSTs a pendnt
// approval request (title = tool name, details = a JSON preview of the tool input),
// long-polls it to a terminal state (bounded by PENDNT_APPROVAL_TIMEOUT_TOTAL_S), and
// translates the result into the SDK's PermissionResult shape.
import { query, type CanUseTool, type PermissionResult } from "@anthropic-ai/claude-agent-sdk";
import { isApproved, requestApprovalAndWait } from "./pendnt.js";

const TOTAL_TIMEOUT_S = Number(process.env.PENDNT_APPROVAL_TIMEOUT_TOTAL_S ?? 600); // 10 min default

function summarizeInput(input: Record<string, unknown>): string {
  try {
    const json = JSON.stringify(input, null, 2);
    return json.length > 4000 ? `${json.slice(0, 4000)}\n...(truncated)` : json;
  } catch {
    return String(input);
  }
}

const canUseTool: CanUseTool = async (toolName, input, options): Promise<PermissionResult> => {
  if (!process.env.PENDNT_API_KEY) {
    return { behavior: "deny", message: "PENDNT_API_KEY is not set — denying by default (nobody to ask)." };
  }

  const title = `Approve tool call: ${toolName}`;
  const details = [
    `tool: ${toolName}`,
    `toolUseID: ${options.toolUseID}`,
    options.description ? `description: ${options.description}` : undefined,
    "",
    "input:",
    summarizeInput(input),
  ]
    .filter((line): line is string => line !== undefined)
    .join("\n");

  let row;
  try {
    row = await requestApprovalAndWait(title, details, TOTAL_TIMEOUT_S, options.signal);
  } catch (err) {
    return { behavior: "deny", message: `pendnt: failed to get an answer (${(err as Error).message}) — denying by default.` };
  }

  if (isApproved(row)) {
    return { behavior: "allow", updatedInput: input };
  }

  const reason =
    row.status === "pending"
      ? `no answer within ${TOTAL_TIMEOUT_S}s (request ${row.id})`
      : row.status === "expired"
        ? "request expired before it was answered"
        : row.status === "cancelled"
          ? "request was cancelled"
          : row.answer
            ? `operator answered: ${row.answer}`
            : "denied by operator";

  return { behavior: "deny", message: `pendnt: ${reason} — denying by default.` };
};

async function main() {
  const prompt = process.argv.slice(2).join(" ") || "list the files in the current directory";

  for await (const message of query({
    prompt,
    options: {
      canUseTool,
      // canUseTool only fires when the permission flow falls through to a prompt —
      // "default" mode still auto-approves plenty of read-only tools without asking.
      permissionMode: "default",
    },
  })) {
    console.log(JSON.stringify(message));
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
