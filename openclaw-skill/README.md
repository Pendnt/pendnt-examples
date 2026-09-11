# pendnt OpenClaw skill

`pendnt/` is a self-contained OpenClaw skill directory — `pendnt/SKILL.md` is the full
writeup (when to use it, the MCP-vs-REST call paths, the cron poll-by-id pattern,
secrets config, and what to verify before publishing to ClawHub). This top-level
`README.md` is just a pointer; start at [`pendnt/SKILL.md`](pendnt/SKILL.md).

```
openclaw-skill/
  pendnt/
    SKILL.md            the skill itself — frontmatter + full instructions
    scripts/pendnt.sh    curl/jq helper the skill tells the agent to exec
    mcp.example.json      example remote-MCP wiring, if your OpenClaw runtime supports it
```

This skill has not been published to ClawHub — see the "Before publishing this to
ClawHub" section at the bottom of `pendnt/SKILL.md` for what to verify first.
