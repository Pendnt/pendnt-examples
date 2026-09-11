// pendnt + Claude Agent SDK (TypeScript) — wiring the hosted pendnt MCP server
// directly into query(), so the model can call request_approval/notify/wait_for_event/
// schedule_wakeup/kv_* itself instead of (or in addition to) canUseTool intercepting
// its own tool prompts. See /root/work/app/README.md's "Remote MCP server" section for
// the full tool list and /root/product/INTEGRATIONS.md §2 ("MCP with auth headers").
//
// Run:
//   PENDNT_API_KEY=aio_... npm run demo:mcp -- "ask me for approval before continuing, then say done"
import { query } from "@anthropic-ai/claude-agent-sdk";

const PENDNT_URL = (process.env.PENDNT_URL ?? "https://api.pendnt.dev").replace(/\/+$/, "");

async function main() {
  const prompt = process.argv.slice(2).join(" ") || "call the pendnt whoami tool and report what it returns";

  for await (const message of query({
    prompt,
    options: {
      mcpServers: {
        pendnt: {
          type: "http",
          url: `${PENDNT_URL}/mcp`,
          headers: { Authorization: `Bearer ${process.env.PENDNT_API_KEY ?? ""}` },
        },
      },
      // Only expose pendnt's own tools (request_approval, check_request, notify,
      // create_endpoint, list_endpoints, wait_for_event, schedule_wakeup,
      // list_wakeups, cancel_wakeup, kv_get, kv_set, kv_delete, whoami) — see
      // /root/work/app/README.md's "Tools" table for the full list.
      allowedTools: ["mcp__pendnt__*"],
    },
  })) {
    console.log(JSON.stringify(message));
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
