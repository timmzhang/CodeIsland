---
name: permission-answered-in-the-agents-own-ui
description: >
  When the user answers a tool approval in the agent's own UI instead of on our
  card, each provider tells us in a different way — or not at all. Claude Code
  emits NO signal for an approval (only for a denial), so its mirror card cannot
  be dismissed before the approved tool finishes. Codex Desktop does emit one
  (thread/status/changed leaving waitingOnApproval) and we act on it. Don't
  "fix" the Claude side by inventing a signal that doesn't exist.
globs:
  - "Sources/CodeIsland/AppState+ToolUseCache.swift"
  - "Sources/CodeIsland/AppState+CodexAppServer.swift"
  - "Sources/CodeIsland/HookServer.swift"
---

## The situation

Our approval card and the agent's own permission prompt are two front-ends for
one decision. Whichever is answered first wins; the other one is stale and must
be taken down. Answering on **our** card always works — the hook response is the
decision, and the agent closes its own prompt. The hard direction is the other
one: the user answers in the agent's UI, and we have to find out.

## What each provider actually gives us

| Provider | Approve elsewhere | Deny elsewhere |
|----------|-------------------|----------------|
| Claude Code (CLI + Desktop) | **Nothing.** | `PermissionDenied` hook — real time. |
| Codex Desktop (app-server) | `thread/status/changed` drops the `waitingOnApproval` active flag — real time. | Same notification. |
| Codex CLI, and every other hook-only provider | Nothing. | Provider-dependent. |

### Why Claude has no approve signal (verified, don't re-litigate)

Claude Code races the `PermissionRequest` hook against its own terminal prompt
in a single `Promise.race`:

- The **hook** wins → Claude calls `abort()` on the prompt request. Our card's
  answer closes the terminal prompt. This is the direction that works.
- The **terminal** wins → Claude returns the user's answer and simply drops the
  losing hook promise. It does not abort it, kill the hook process, close its
  pipes, or write anything to the transcript.

Measured against Claude Code 2.1.231 with a deliberately blocking
`PermissionRequest` hook in a real interactive session: **31 s after the user
answered in the terminal the hook process was still alive**, with no signal, no
EOF and no `SIGPIPE`.

Two more facts that close off the obvious workarounds:

- Claude's `PermissionRequest` payload carries **no `tool_use_id`** (only
  `session_id` / `tool_name` / `tool_input` / `permission_suggestions`), so a
  queued card has no id to correlate on.
- The transcript's `hook_permission_decision` attachment is written **only when
  a hook produced the decision** (`decisionReason.type === "hook"`). A terminal
  answer writes no attachment, so `resolvePermissionFromTranscript` cannot fire
  for this case by construction.
- There is no "permission granted" hook event anywhere in Claude's event set —
  `PermissionDenied` has no positive counterpart.

So for Claude, an approval given in the terminal is first observable at
`PostToolUse`, i.e. **after the approved tool has finished running**. That is
what `resolveToolUseIfCompleted`'s (session, tool, input) fallback and
`resolveOrphanPermissionsOnActivity` already cover, and it is the earliest
possible moment — not a bug in our code.

## Rule

1. Do not add a Claude-side "approved elsewhere" detector. There is no signal to
   detect. If a report says the card lingers, check that the existing
   `PostToolUse` correlation still fires; the residual delay is the tool's own
   runtime.
2. When a provider *does* expose a real-time resolution signal, drain
   `permissionQueue` from it — updating `SessionSnapshot.status` alone leaves the
   card on screen. This is what `applyCodexThreadStatusNotification` →
   `resolveCodexPermissionsResolvedElsewhere` does.
3. Release such a waiter with an **empty hook response** (`{}`), never
   allow/deny. A "no longer waiting" signal says the approval is over but not
   which way it went; asserting a decision can contradict the user's real answer
   if the provider still reads the response.
4. Only drain when the provider previously told us it *was* waiting on approval.
   A bare "not waiting" notification can race ahead of the hook that opened the
   card and would kill a live prompt.
