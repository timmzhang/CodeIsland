---
name: browser-use-prompt-is-origin-gated
description: >
  Codex's "Allow Browser use to access <origin>?" prompt is asked at most once per
  origin and the answer is persisted under $CODEX_HOME/browser/. Those files are the
  only signal CodeIsland gets — the prompt itself reaches no hook and no rollout
  event. Never decide "a browser call is probably blocked" from elapsed time alone:
  a quarter of ordinary browser calls run longer than 2s.
globs:
  - "Sources/CodeIsland/BrowserUseOriginPolicy.swift"
  - "Sources/CodeIsland/AppState+BrowserUseAttention.swift"
---

## The prompt

Browser Use asks, inside Codex's own TUI:

```
Allow Browser use to access http://localhost:38081?
origin: http://localhost:38081
  1. Allow            Run the tool and continue.
  2. Always allow     Run the tool and remember this choice for future tool calls.
  3. Cancel           Cancel this tool call
```

It is **per origin**, not per call, and the answer is written to disk:

| Answer | File |
|--------|------|
| Always allow | `$CODEX_HOME/browser/config.toml` → `[origins] allowed` |
| Allow (this session) | `$CODEX_HOME/browser/sessions/<threadId>.toml` → `[origins] allowed` |
| Cancel | the same session file → `[origins] denied` |

So an origin that appears in either file **cannot** raise the prompt again: allowed
runs straight through, denied fails outright.

## What we do and don't observe (verified, don't re-litigate)

- The prompt is **not** a hook event. Only `PreToolUse(mcp__node_repl__js)` arrives;
  there is no `PermissionRequest`, and the denied path never sends `PostToolUse`.
- It is **not** in the rollout either. `mcp_tool_call_end` carries the outcome
  (`_meta.codex/browserUse`, `browser_use.url`), never the question. Grepping a full
  `~/.codex/sessions` history for the prompt text finds only agent prose quoting it.
- CodeIsland's app-server client cannot intercept it. That client is a *second*
  `codex app-server` process; a CLI session's `requestUserInput` never reaches it
  (measured in p-3q1u).

The origin files are therefore the only machine-readable trace, and they answer the
one question that matters: *can this call prompt at all?*

## Rule

1. Gate the Browser Use attention card on `BrowserUseOriginPolicy`, not on a timer.
   An origin already allowed or already denied gets no card, however long the call
   runs.
2. Duration is a fallback for calls whose code carries no URL (a click that navigates
   somewhere new), and only at a threshold real calls don't reach. Measured over 145
   timed browser calls in this user's history: median 228 ms, but **27% exceed 2 s**
   and 1% exceed 8 s. The original 2 s trigger fired on 39 of those 145 calls, none of
   which was waiting on anything.
3. Re-read the policy when the delay matures. The user may have answered during the
   wait, which settles the origin and retires the card before it is ever shown.
4. Don't reach for a "positive" signal that isn't there — see the verified list above.
   If coverage must improve, it improves through the origin files, not through
   guessing harder at timing.
