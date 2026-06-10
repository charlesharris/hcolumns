# hcolumns — Design Note

**Status:** Charter / shaping. Decisions captured here are working agreements, revisable.
**Date:** 2026-06-10

This is the Ruby playground's own charter — distinct from the VRIDE design in `~/src/vride/docs/`,
and from the prior `hugel` projects. Those inform it; this doc governs what we build here.

---

## 1. What this is

`hcolumns` (Harris Columns, "h-columns") is a Ruby playground for one idea:

> **A structured, directed way to explore a property graph** — the same data a Neo4j-style graph
> browser holds (nodes, typed/directed/weighted relationships, properties), but rendered as a
> ranked, relation-grouped, walkable cascade of columns instead of a freeform canvas.

It generalizes the Miller (folder) column: "children of a folder" is the special case where the
only relation is `CONTAINS`. A column is **top-k related nodes from the current selection, grouped
by relation type, ranked by a tuner, with evidence on each entry.**

**Guiding-star application (VR deferred):** powering a UI for **building together with an LLM
coding agent** — columns explore existing code, proposed changes, new code, git/commit trees, app
logs, etc.; the agent's edits/chats/questions feed the graph; the columns reflect the session.
This is *one application* of the general explorer, not the definition of it.

**Lineage:** this revisits the columns UI the `hugel` line kept deferring (hugel-v1/_v2 chose
"dashboard + drill-down, not columns"). hugel built the *mound* (a composted, sometimes
event-sourced knowledge substrate); hcolumns asks whether semantic columns are the better surface
to grow on it. See the project memory for the full lineage.

---

## 2. The core idea: a structured Neo4j browser

| Neo4j browser (freeform canvas) | Harris columns (structured + directed) |
|---|---|
| expand node → neighbors scatter | expand node → neighbors grouped by relation type, ranked, as a column |
| arrange the cloud by hand | layout implied by the cascade |
| accreted hairball, no inherent path | left→right cascade *is* the path walked — direction is free |
| every node equal until read | ranking surfaces high-signal neighbors first |

"Structure" = grouping by relation type + ranking. "Direction" = the Miller-column cascade, which
remembers where you've been and frames where you can go. The canvas is good for *territory*; the
columns are good for *routes*. Both read the same graph (cf. VRIDE §7.2).

---

## 3. The substrate: a property graph

Nodes + typed, directed, weighted relationships + properties. Deliberately Neo4j-/Pile-shaped, so
a real `hugel` Pile can later slot in as a provider (decision **a+c** below).

- **Node (Object):** `id`, `type`, `labels`, `properties`, identity `{scheme, key}` (id = hash of
  the pair; cross-source sameness is a `SAME_AS` edge, never a merge — preserves provenance).
- **Edge (relationship):** `subject → object`, `type`, `weight`/`confidence`, and **provenance**
  (which observations/sources produced it). Confidence is derived, never hand-set as truth.
- **Vocabulary** leans on the hugel model where it fits: relations like `CONTAINS`, `RELATES_TO`,
  `SUPERSEDES`, `EVOLVED_FROM`, `PRODUCED_IN`; agent-era types like `PROPOSES_CHANGE_TO`,
  `TOUCHES`, `ASKS_ABOUT`. Entry-style node types (decision/pattern/pitfall/…) arrive as needed.

### Decision a+c (substrate ownership)

hcolumns **carries its own minimal in-process substrate**, **shaped compatible** with the hugel
Entry/edge model — so a real Pile slots in later as one provider — but is **not coupled** to
Neo4j/Rails now. It must run standalone. (Rejected: (b) requiring a live Pile.)

---

## 4. Providers: many sources, one graph

A source becomes part of the graph by **appending nodes + edges with evidence** — it never draws
the column directly. This is what makes the column source-agnostic ("fed by many sources" =
nutrition for the mound). The column layer only ever sees nodes + ranked edges.

MVP-candidate providers: filesystem/code, git (history, co-change), a log-file reader, an
in-memory graph fixture (golden-test substrate), a replayed agent-session fixture. Later: a hugel
Pile, OTel traces, a live agent.

---

## 5. The column + the tuner

```
selected node → [ column: top-k edges, grouped by relation type, ranked ] → select → next column
                  each entry: target node, relation, confidence/maturity,
                  a one-line rank reason, evidence/provenance, available actions
```

The **tuner** is the ranking function (re-weight, don't toggle): confidence, evidence match,
recency, proximity (hops), novelty, minus fragility. Knobs re-weight terms so the same graph
yields different surfaces with no recompute. Ranking is a total order (score desc, tie-break by id)
so output is deterministic and golden-testable.

---

## 6. Storage stance: decouple display from truth

The columns read a **property-graph read-model**. *How that graph is stored is an implementation
detail under the display*, and the lineage already built both options:

- **mutable graph w/ provenance+confidence on edges** (hugel_v2 style) — simplest, Pile-shaped.
- **event log → folded projection** (hugel3 style) — enables agent undo, live/frozen snapshots,
  time-travel, multi-actor merge.

**MVP:** start with the mutable-graph-with-provenance behind the read-model interface. Keep the
seam so the event log slots underneath **when a feature needs it** — the agent guiding-star will
(undo, snapshots), and hugel3 already proves the pattern. Don't pay for the log until something
wants it; design so adding it is a slot-in, not a rewrite. ("Grow small and slow.")

---

## 7. Hügel posture (how we treat the substrate)

- **Non-destructive:** prefer soft-deprecate / `EVOLVED_FROM` over delete; stale structure
  decomposes (loses confidence) rather than being ripped out.
- **Decay is first-class:** confidence/recency fade over time; surfaced early even if the math is
  crude. A stale edge carrying false confidence is worse than no edge.
- **The substrate is the product**, not a derived cache.
- **Emergence over schema:** permissive ingest; structure (grouping, ranking, hubs) at query time.
- **Grow small and slow:** each layer runs and is tested before the next is added.

---

## 8. MVP scope (first runnable layer)

In: the property-graph substrate (mutable + provenance); a couple of contrasting providers
(in-memory graph fixture + one real source); the tuner (at least confidence + recency); the column
builder; a session-rooted text renderer that walks the cascade; golden tests over fixtures.

Out (for now): event log/undo/snapshots, live agent wiring, code-rooted view, a real Pile, OTel,
graph-canvas view, persistence beyond a simple on-disk file, VR.

---

## 9. Open questions

1. The columns thesis to earn: do "structure + direction" beat the freeform canvas *enough* to
   justify the constraint? Validate against a real route on the corpus.
2. First real provider to pair with the in-memory fixture — code/filesystem, a log file, or a
   replayed agent session?
3. Renderer: plain CLI print first, or straight to an interactive terminal cascade?
4. Persistence: when does the mound move from in-memory to on-disk, and in what format?
