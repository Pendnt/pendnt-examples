#!/usr/bin/env python3
"""Minimal LangGraph graph with a human-approval node implemented by pendnt.

Graph shape:

    prepare -> human_approval -> [approved] -> act -> END
                              \-> [denied]   -> stop -> END

`human_approval` plays the role LangGraph's own `interrupt()` plays in a
human-in-the-loop graph (pause a run for a human decision), but instead of pausing via
LangGraph's checkpointer + `Command(resume=...)` machinery, it blocks synchronously
inside the node on a pendnt approval request (create + long-poll) -- see
pendnt_gate.py. That keeps this example runnable end-to-end with `python3 graph.py`
and no checkpointer/persistence setup; swap in real `interrupt()` if you want the graph
itself to suspend and be resumed from a different process later (pendnt's request id is
exactly the durable handle you'd stash for that resume).

Run:
    PENDNT_API_KEY=aio_... python3 graph.py "delete the old backups"
"""

from __future__ import annotations

import os
import sys
from typing import Literal, TypedDict

from langgraph.graph import END, START, StateGraph

import pendnt_gate

TOTAL_TIMEOUT_S = float(os.environ.get("PENDNT_APPROVAL_TIMEOUT_TOTAL_S", "600"))


class GraphState(TypedDict):
    task: str
    decision: str  # "" | "approved" | "denied"
    result: str


def prepare(state: GraphState) -> GraphState:
    return {**state, "decision": ""}


def human_approval(state: GraphState) -> GraphState:
    title = f"Approve: {state['task']}"
    details = f"A LangGraph run wants to proceed with:\n\n{state['task']}"
    row = pendnt_gate.request_approval_and_wait(title, details, TOTAL_TIMEOUT_S)
    decision = "approved" if pendnt_gate.is_approved(row) else "denied"
    print(f"[human_approval] request {row.id} -> status={row.status} -> decision={decision}")
    return {**state, "decision": decision}


def route_after_approval(state: GraphState) -> Literal["act", "stop"]:
    return "act" if state["decision"] == "approved" else "stop"


def act(state: GraphState) -> GraphState:
    return {**state, "result": f"done: {state['task']}"}


def stop(state: GraphState) -> GraphState:
    return {**state, "result": f"not approved, skipped: {state['task']}"}


def build_graph():
    graph = StateGraph(GraphState)
    graph.add_node("prepare", prepare)
    graph.add_node("human_approval", human_approval)
    graph.add_node("act", act)
    graph.add_node("stop", stop)

    graph.add_edge(START, "prepare")
    graph.add_edge("prepare", "human_approval")
    graph.add_conditional_edges("human_approval", route_after_approval, {"act": "act", "stop": "stop"})
    graph.add_edge("act", END)
    graph.add_edge("stop", END)

    return graph.compile()


def main() -> None:
    task = " ".join(sys.argv[1:]) or "delete the old backups"
    app = build_graph()
    final_state = app.invoke({"task": task, "decision": "", "result": ""})
    print(final_state["result"])


if __name__ == "__main__":
    main()
