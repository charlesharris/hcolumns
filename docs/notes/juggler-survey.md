# Juggler survey — what to take, what to skip, and why

**Date:** 2026-07-14 · **Subject:** `~/src/juggler` (v0.3.7, active) · **Status:** takeaways #1/#2 adopted (see STATUS layers 26–27)

Juggler is "another AI coding agent" whose angle is a **visual workbench**: inspectable
tool calls, branching threads, editable context, rendered as **Finder-style Miller
columns**. Go server + type-checked-JS UI, session documents in Yjs, everything-as-
extension. It overlaps hcolumns so heavily that it reads like the same thesis attacked
from the opposite shore — which makes it the most useful external reference we have.

## The core symmetry

Juggler's manifesto (`web/js/model/blurb.md`): *"Context should be a document, not a
log."* The session is a Yjs **tree** (threads nest sub-threads; every tool call /
thinking block / message is a typed item), and what the LLM sees is **projected fresh
from the live tree every turn** — never stored. Editing the past is editing the
document.

hcolumns: *the log is truth, the graph is a projection, columns are a rendering.*
Juggler: *the document is truth, the LLM context is a projection, columns are a
rendering.* Both reject the transcript as the artifact; each picked one pole:

| | juggler | hcolumns |
|---|---|---|
| Truth | mutable CRDT document (editable past) | append-only event log (immutable past + replay) |
| Projection | LLM context, rebuilt each turn | property graph, folded from events |
| Columns walk | the conversation tree | a semantic evidence graph |
| Cross-session residue | one flat `MEMORY.md` | the whole point (the mound) |
| Relations | positional (tree order) | typed, weighted, evidenced, decaying |
| Ranking | chronological | confidence × lens |

Juggler has **no evidence model, no semantic edges, no provenance/decay, no
cross-session substrate**. It is a serious *session/interaction* layer; hcolumns is a
serious *knowledge* layer. Complementary — juggler is close to a proof-of-demand for
what hcolumns' guiding star wants to exist underneath a tool like it: a bridged
juggler-shaped session landing in our graph makes "which sessions touched this file,
and what did they conclude" answerable — a query juggler structurally cannot ask.

## Their architecture in one breath

The **Go worker owns everything**: one goroutine per conversation owns the y-crdt doc
(source of truth), runs the agent loop, drives the tool lifecycle, persists
(`cmd/juggler/worker/`). The JS "engine" is a hidden headless client that only
executes tools and serializes context (extensions run there); browsers/desktop app are
pure viewer peers. Sync is CRDT updates over WS/WebRTC with per-client ordered
mailboxes. Their AGENTS.md: **"No mutexes. Use goroutines + channels"** — same
single-writer instinct as our log-is-truth stance, achieved with an owner-goroutine
instead of an append-only file.

Notable mechanics (with sources):

- **Item = typed Y.Map in a flat `items` array**; `thread` items nest their own
  `items` (the tree). Schema doc: `web/js/model/SCHEMA.md`.
- **`tool-action` state machine**: `pending → approved → running → completed |
  cancelled`; the `approved`/`running` split is an atomic compare-and-set claim.
  Lifecycle is command-driven from the worker; **invariants live in reactive Yjs
  observers, never click handlers** (holds uniformly for click, undo, redo, peer sync).
- **Transaction blobs**: every LLM round-trip persisted write-once to
  `txns/<txnID>.json` (full input context, output blocks, tokens) *before* further
  mutation; items reference blobs by `transactionId`; GC is **undo-aware** (a blob
  lives while anything resurrectable references it). Backs a "View Transaction"
  inspector column. `cmd/juggler/worker/transaction_store.go`.
- **Sub-thread isolation + stack pop**: a sub-thread inherits only the *leading run*
  of standing context at root (system prompt, agents files, memory) plus its own
  items — never the parent's working reads (`document.go` `GetContextItemIDsForThread`:
  "Inheriting all of it caused sub-threads to redo their parent's work"). A completed
  thread projects into context as ONE line: `[Completed Thread: <goal>] … <result>`.
  Their framing: threads are the **stack**, standing context the **heap**.
- **`/compact` is a document fold, not a code path**: sweep conversational items into
  a new sub-thread seeded with a summarization prompt + `forceTool: 'return_result'`,
  one atomic transaction (undo reverses it whole); the summary comes back through the
  normal loop. `/handoff` reuses the same fold. `web/js/utils/compaction-utils.js`.
- **ContextItem = the whole vertical slice**: one class owns the tool schema, the
  executor, the LLM-facing serialization, AND the UI. Explicit doctrine at the
  `renderToolActionDetails` boundary: *"if you find yourself adding
  `if (toolName === 'foo')` to a component, override this method instead"* — their
  version of our "the column never knows what a log line is".
- **Strategies shape the loop, never own it** (`filterTools`, `getApprovalPolicy`,
  `injectGuidance`, `onWorkerIdle`) — their version of "re-weight, don't toggle".
- **Two file-content contracts**: `read_file` = immutable snapshot at call time
  (history); `@file` pin = path only, resolved **live at send time** (no watcher, no
  cache, no doc bloat). Independently identical to our observations-vs-content-facets
  split — two projects hitting the same distinction is evidence it's load-bearing.
- **Claude Code CLI bridge**: parked subprocess speaking JSON-lines; tool calls arrive
  as in-process MCP, get parked, run out-of-band (approval + engine), results unblock
  the CLI via `control_response`. Disciplines worth keeping: **never strand a
  request** (a delegated thread always yields a result — promote trailing text →
  fallback) and **cache purity** (system-prompt contributions must be pure functions
  of the enabled-capability set). `cmd/juggler/providers/claudecode/doc.go`.
- **Column UI**: a pure DOM-free `ColumnSelectionState` (select in column *i* →
  truncate selections > *i*; `resolveColumnChain` walks the tree: thread → another
  list column, leaf → properties column, stop). One **badge resolver** feeds both
  list tile and detail header so they can never drift. Detail render debounced 150ms
  behind arrow-key traversal. Auto-follow into LLM-opened threads has a **5s cooldown
  after any manual interaction**. `web/js/utils/column-selection.js`,
  `web/js/utils/item-badge.js`, `web/js/components/conversation-tab.js`.
- **Approval suggestions are dry-run verified**: "don't ask again" tiers are only
  offered if `approvesWith()` confirms the rule would genuinely auto-approve the
  command in hand. `web/extensions/juggler-core/context-items/execute-context-item.js`.

## Takeaways adopted

**#1 — Turn grouping (their `transactionId`).** Their every-item-carries-its-round-trip
provenance + write-once blobs answers "why does this item exist". Our analogue stays
event-sourced: a `:turn` **marker event** partitions the log; turn membership is
**derived at fold time from log order** (no per-event stamping by producers — the
stateless bridge just emits the marker). Feeds the long-open "Inspector depth" thread:
the inspector shows which turn produced each observation; a `turns` facet on the
Session lists turns with their touched nodes, walkable.

**#2 — Tool-lifecycle states as events.** Their `pending → running → completed` is
what makes in-flight work visible in columns. Ours rides the **existing** re-emit
pattern (layer 12's `:phase`: latest node fold wins): `test start <cmd>` emits a
TestRun in `:running`, `test ok|fail <cmd>` re-emits the same node (digest-keyed
identity) in its final state. No new event kind. The designed-in next step (not built
— needs a driving use case): **approval as an interaction event** on a pending node,
structurally identical to layer-21 flags.

## Deliberate divergence: keep the log, skip the CRDT

Juggler pays real costs for the editable past: **branching is copy-the-whole-
conversation** (clone doc + blobs + assets; refused mid-turn), undo is a bespoke
worker-owned UndoManager with a custom tombstone filter, and invariants must be
policed reactively because anyone can mutate anything. Our append-only log gets
**branch-at-seq-K for free** (fold events ≤ K, then diverge), and "editing the past"
is a `:retract` counter-event — provenance preserved, replay deterministic. The CRDT
buys them true collaborative mutation of shared state; our clients only ever *append*
(flags, bridge events), so single-writer-log + many-readers stays sufficient. If
collaborative editing is ever wanted, that's the moment to reread this note — not
before.

## Parked (worth stealing later, when a use case drives)

- **Sub-session tree + stack pop** — bridge verbs `thread <goal>` / `endthread
  <result>`; a completed sub-session folds to a summary node, detail still walkable
  beneath. Gives the sessions index real shape.
- **Auto-follow cooldown** (5s after manual interaction) for the live walk's
  auto-mode re-resolution — softer complement to pinning.
- **Badge resolution in the data contract** — glyph/status semantics resolved once in
  Panel/serializer, never per-renderer (we're partway there).
- **Debounced detail render** for the web dock.
- **Dry-run approval suggestions** (`approvesWith`) if we ever grow rule suggestions.
- **A no-code tier** (their markdown custom commands below extensions) — e.g. YAML
  lens presets.
- **Compaction-as-document-fold** — graph operations (summarize a session) modeled as
  events + a bridge round-trip rather than bespoke code.
