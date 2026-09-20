---
name: browser-use-prompt-is-origin-gated
description: >
  Codex's "Allow Browser use to access <origin>?" prompt is gated on navigation and
  asked at most once per origin; the answer is persisted under $CODEX_HOME/browser/.
  The code about to run plus those files are the only signal CodeIsland gets — the
  prompt itself reaches no hook and no rollout event. Never decide "a browser call is
  probably blocked" from elapsed time alone: a quarter of ordinary browser calls run
  longer than 2s, and most of them cannot navigate anywhere.
globs:
  - "Sources/CodeIsland/BrowserUseOriginPolicy.swift"
  - "Sources/CodeIsland/BrowserUseCallShape.swift"
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

It is asked **only when the browser is sent somewhere** — `goto`, `navigate`,
`getForUrl`, `tabs.new(url)`, `cua.createBrowserTab(browserId, url)`, or a click /
`pressKey` that follows a link off-origin. Reads of the
page already open (`evaluate`, `domSnapshot`, `innerText`, `screenshot`, locator
queries) never raise it, *including* an in-page `fetch("https://other.example/…")`:
that request is the page's, not a navigation. `reload` / `goBack` / `goForward`
revisit an origin the browser is already on, which by definition has an answer.

The allow list is the evidence: every origin in it is one this user navigated to,
and `ti-platform.lark-us.net` — fetched from inside a page many times over — has
never appeared there.

It is **per origin**, not per call, and the answer is written to disk:

| Answer | File |
|--------|------|
| Always allow | `$CODEX_HOME/browser/config.toml` → `[origins] allowed` |
| Allow (this session) | `$CODEX_HOME/browser/sessions/<threadId>.toml` → `[origins] allowed` |
| Cancel | the same session file → `[origins] denied` |

So an origin that appears in either file **cannot** raise the prompt again: allowed
runs straight through, denied fails outright.

## What we do and don't observe (verified, don't re-litigate)

- The prompt is **not** a hook event. Only the `PreToolUse` for the `js` call arrives;
  there is no `PermissionRequest`, and the denied path never sends `PostToolUse`.
- The same runtime answers to **two MCP server names**: `mcp__node_repl__js` (the
  standalone Browser plugin) and `mcp__cua_repl__js` (the unified Computer Use plugin
  the Codex desktop app installs, which also drives native apps via `cua.getApp`).
  Both raise the identical prompt and write the identical `$CODEX_HOME/browser/`
  files — verified 2026-09-20 when a `cua_repl` "Always allow" appended
  `http://127.0.0.1:63778` to `browser/config.toml`. Keying the card on one name
  silently drops the other (p-6jnh: an eight-minute stall with no card).
- It is **not** in the rollout either. `mcp_tool_call_end` carries the outcome
  (`_meta.codex/browserUse`, `browser_use.url`), never the question. Grepping a full
  `~/.codex/sessions` history for the prompt text finds only agent prose quoting it.
- CodeIsland's app-server client cannot intercept it. That client is a *second*
  `codex app-server` process; a CLI session's `requestUserInput` never reaches it
  (measured in p-3q1u).

The code being run and the origin files are therefore the only machine-readable
traces, and together they answer the one question that matters: *can this call prompt
at all?*

## Rule

Ask the question in this order — the cheap structural answers come first, and the
clock is the last resort, never the first.

1. **Can the call navigate?** `BrowserUseCallShape.read` answers from the source. No
   navigation → no card, at any duration, ignoring any explicit delay a caller passes
   in. This is the single biggest source of false alarms: a URL somewhere in the code
   is not a destination.
2. **Is the destination settled?** For a literal URL, `BrowserUseOriginPolicy` decides.
   Already allowed or already denied → no card, however long the call runs.
3. **Only then, how long has it run?** 2 s for a fresh literal origin, 10 s for a
   navigation whose URL comes from a variable, 15 s for a click that might follow a
   link. The two weak triggers also add the script's own declared waits
   (`waitForTimeout(28000)` and friends, capped at 60 s) — a call is only evidence of a
   stall for the time it runs *beyond* what it asked to sleep. The strong trigger does
   not: there the prompt blocks the navigation up front, so waiting on a later sleep
   would just hide it.
4. **Re-read the policy when the delay matures.** The user may have answered during the
   wait, which settles the origin and retires the card before it is ever shown.
5. **Don't reach for a "positive" signal that isn't there** — see the verified list
   above. Coverage improves through the call's source and the origin files, not through
   guessing harder at timing.

## Measured

Replaying every Browser Use call in `~/.codex/sessions` (1786 calls that touch the
browser API) against the origin files, including the per-thread session files:

| Rule | Cards raised |
|------|--------------|
| Duration only (2 s / 10 s) | 179 |
| + origin policy | 52 |
| + navigation gate, declared-wait budget | 8 |

Four of the surviving eight are synthetic acceptance scripts written to fire on
purpose. Of the four real ones, the two longest — a 673 s click that followed a link to
`bitscloud-orca.byted.org` and a 384 s `goto` to a fresh local port — are the case the
card exists for. The 52 the origin policy left behind were overwhelmingly polling
loops and page reads: code that sleeps 28 s on purpose, or snapshots a page it is
already sitting on.
