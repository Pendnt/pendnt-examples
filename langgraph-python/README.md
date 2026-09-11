# pendnt + LangGraph

A minimal [LangGraph](https://pypi.org/project/langgraph/) graph with a human-approval
node implemented by pendnt:

```
prepare -> human_approval -> [approved] -> act  -> END
                          \-> [denied]   -> stop -> END
```

`human_approval` (`graph.py`) plays the role LangGraph's own `interrupt()` plays in a
human-in-the-loop graph — pausing a run for a human decision — but instead of
suspending via LangGraph's checkpointer + `Command(resume=...)` machinery, it blocks
synchronously inside the node: create a pendnt approval request, long-poll it to a
terminal state (`pendnt_gate.request_approval_and_wait`), and route on the result. That
keeps this example runnable end-to-end with a single `python3 graph.py` and no
checkpointer/persistence setup to wire up.

If you want the graph itself to actually suspend the process and be resumed later
(hours or days after the human answers, from a different process) rather than block
in-node, swap in LangGraph's real `interrupt()`/checkpointer flow and use the pendnt
request's `id` as the durable handle you stash and resume on — the poll-based node here
is the simpler starting point.

## Setup

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export PENDNT_API_KEY=aio_...
export PENDNT_URL=https://api.pendnt.dev   # optional, this is the default
```

## Run

```bash
python3 graph.py "delete the old backups"
```

Approve or deny the request from `https://pendnt.dev/dashboard` (or a configured email/
Telegram channel) while it's polling; the graph prints which branch it took and the
final `result`.

## Files

- **`pendnt_gate.py`** — a standalone (no cross-directory import, stdlib-only) pendnt
  REST client: `request_approval_and_wait` (`POST /v1/requests` + long-polling
  `GET /v1/requests/:id?wait_s=25`) and `is_approved` (treats a free-text answer
  starting with yes/y/allow/approve/ok as approval — the operator answer page always
  shows a free-text box, even for approval-kind requests). Deliberately duplicated
  from `../claude-agent-sdk-python/pendnt.py` rather than imported, so this directory
  stands alone.
- **`graph.py`** — the graph: `StateGraph` with a `TypedDict` state
  (`task`, `decision`, `result`), four nodes, one conditional edge routing on the
  approval decision.

## Verified

- `python3 -m py_compile pendnt_gate.py graph.py` — syntax-checked.
- Installed `langgraph==1.2.11` (pinned in `requirements.txt`, confirmed to exist on
  PyPI) into a real virtualenv and imported `graph.py` — `build_graph()` compiles
  successfully and reports the expected node set
  (`prepare`, `human_approval`, `act`, `stop`, plus LangGraph's `__start__`/`__end__`).
