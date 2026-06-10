# hcolumns — Status & Handoff

**Updated:** 2026-06-10 · **Branch:** `main` · **Tests:** 34 examples, 0 failures · **Runtime deps:** none (rspec is dev-only)

This is the "where we are / how to resume" doc. For the *why* see [`DESIGN.md`](DESIGN.md)
(the charter); deeper decision history lives in the project memory.

---

## 1. What this is (one breath)

`hcolumns` ("Harris Columns", h-columns) is a Ruby playground for **semantically-directed
Miller columns**: a structured, directed way to explore a **property graph** (nodes + typed
/weighted edges + properties — the same data a Neo4j browser holds), rendered as ranked,
relation-grouped, **walkable columns** instead of a freeform canvas. "Children of a folder" is
the special case where the only relation is `CONTAINS`.

**Guiding star (VR deferred):** power a UI for building *with* an LLM coding agent — columns
explore code, proposed changes, git history, logs, etc.; the agent is a first-class event
source. Part of the hügel lineage (`~/src/hugel*`, `~/src/vride`): compost-and-grow posture,
the substrate is the product, decay is first-class.

## 2. The pipeline

```
providers append Observations         (filesystem, git, naming-rules, a human, an agent, ...)
   └─> Graph folds them into Edges     (derived confidence + maturity + provenance)
        └─> Tuner scores each edge      (re-weight, don't toggle)
             └─> ColumnBuilder groups & ranks   (by relation type; total order)
                  └─> a Renderer displays        (text column, or side-by-side cascade)
   Workspace ties graph+providers together and expands a node's neighbors LAZILY,
   only when its column is first requested (the pull / on-demand seam).
```

The column never knows what a log line or trace span *is* — only nodes + ranked edges. A new
source is just a new provider that appends observations.

## 3. Layers built (all committed on `main`)

| Commit | Layer |
|---|---|
| `0ad2737` | **1** — property-graph substrate (Node, Observation, Edge=fold w/ confidence+maturity+provenance, Graph), evidence model w/ decay on an injected clock, confidence+recency Tuner, ColumnBuilder, in-memory fixture, text renderer, `hcol explore` |
| `8159860` | **2** — interactive Miller-column cascade: `Cascade` (pure nav state), `CascadeText` (side-by-side renderer), `TUI` (raw input, arrows/hjkl), `hcol walk` |
| `bf2bcbc` | **3** — lazy `Workspace` + on-demand provider seam; **filesystem** (`CONTAINS`) and **naming-rules** (`PAIR`) providers; `hcol walk <real-dir>`; alphabetical sibling tiebreak |
| `4b1830f` | fix — TUI staircase (emit CR+LF in raw mode) |
| `17a0917` | **4** — **git** provider: `CO_CHANGED_WITH` (weighted by frequency) + `CHANGED_BY` from real history, on-demand per file |

## 4. File map (`lib/hcolumns/`)

```
identity.rb        {scheme,key} -> obj:<hash>   (cross-source sameness is a SAME_AS edge, not a merge)
evidence.rb        5 kinds (structure|behavior|history|human|inference); type-weight + decay half-life
observation.rb     the primitive providers append; contribution(now) = decay·type_weight·weight
node.rb            graph node (type, identity, properties)
edge.rb            DERIVED fold of observations: confidence (squashed Σ), recency, maturity
graph.rb           nodes + edge projection; observe() folds; edges_from/into
tuner.rb           score = w_conf·confidence + w_recency·recency   <-- KNOBS GO HERE NEXT
column.rb          ColumnEntry / ColumnGroup / Column
column_builder.rb  outgoing edges -> grouped by relation -> total order (score desc, name, id)
workspace.rb       graph + providers; column_for() expands lazily (once per node); the pull seam
cascade.rb         Miller traversal: stack of frames, cursor, into/back, preview, trail
providers/
  in_memory_fixture.rb  demo coding-workspace graph (golden substrate)
  filesystem.rb         CONTAINS, one dir level at a time; skips hidden/.git/node_modules/...
  naming_rules.rb       source<->test PAIR by string transform (heuristic; misses flat spec/ dirs)
  git.rb                CO_CHANGED_WITH + CHANGED_BY; bounded (MAX_COMMITS=100, MAX_FILES/commit=50)
renderers/
  text.rb               single column (maturity glyph, confidence bar, rank reason)
  cascade_text.rb       side-by-side columns + breadcrumb + preview + detail line
tui.rb                  interactive driver (raw mode, arrows/hjkl, q/Esc/Ctrl-C; CR+LF on paint)
cli.rb                  explore / walk / nodes / help; real path -> indexed; else demo selector
```

## 5. What works today

```sh
bundle install
bundle exec rspec                 # 34 examples

# demo graph (in-memory fixture)
./exe/hcol explore                # column for src/orders.rb
./exe/hcol explore repo/          # CONTAINS (folder-style) column
./exe/hcol nodes

# real filesystem + git, indexed lazily
./exe/hcol walk .                 # interactive cascade (arrows/hjkl, → descend, ← back, q quit)
./exe/hcol explore lib/hcolumns/cascade.rb   # shows CHANGED_BY + CO_CHANGED_WITH from git history
```

Verified end-to-end (incl. PTY-driven interactive walks of the real repo). On a real file,
git co-change even surfaces source↔test links the naming heuristic misses — multi-source
evidence covering blind spots.

## 6. Load-bearing decisions (recap; full rationale in memory + DESIGN)

- **Property graph is the substrate**; columns are a structured/directed *rendering* of it
  (a "Neo4j browser with structure and direction"). Charris's framing.
- **Event-sourcing decoupled from display.** Columns read a property-graph read-model. MVP
  uses a mutable graph with provenance+confidence on edges (hugel_v2-style). A real event
  log (hugel3-style: append-only + fold + replay) slots underneath *when a feature needs it*
  (agent undo, live/frozen snapshots). Don't pay for it until then; keep the seam.
- **Providers are on-demand / pull.** Protocol: `recognizes?(node)` + `expand(node, graph, now:)`,
  run once per node. Resolves the design's push/pull ambiguity. All future providers inherit this.
- **Injected clock** everywhere (no wall-clock in fold/scoring/decay) → deterministic,
  golden-testable. Tests pin `FIXED_NOW`.
- **Substrate owned by hcolumns**, shaped compatible with the hügel Entry/edge model so a real
  Pile can later be just another provider. Not coupled to Neo4j/Rails. Runs standalone.
- **UI gems (pastel/tty-reader/...) deferred.** Terminal code isolated to `tui.rb` +
  `cascade_text.rb`; the TUI is a probe, not necessarily the final renderer.

## 7. Known limitations / sharp edges

- **Naming rule is heuristic** — lib↔spec transform misses flat `spec/` layouts (e.g. our own repo).
- **No persistence** — every run rebuilds in memory. (hügel posture wants an accreting on-disk
  log eventually; deferred.)
- **Git provider cost** — up to 2 git subprocess calls per file expansion; bounded but not cached.
- **Tuner is fixed** — `confidence + recency`, no way to retune yet (next layer).
- **No `Rakefile`** — use `./exe/hcol` or `gem build && gem install` for a global `hcol`.
- **Renderer width** — hardcoded `COL_WIDTH`; uses `String#length` (wrong for wide/ambiguous
  glyphs — latent misalignment; `unicode-display_width` would fix, deferred with the UI gems).
- **`homepage` in gemspec is a placeholder**; no `LICENSE` file though gemspec says MIT.

## 8. NEXT UP — tuner knobs (planned, not started)

Goal: make "same graph, different surface" real. The data is now rich enough to tune
(structure / history / human across fixture + real repos).

**Core (in `tuner.rb`, pure re-weighting — golden-test "same selection, knob X → ranking Y"):**
- **Confidence floor** (strict ↔ speculative) — visibility threshold; hide/surface weak edges.
- **Evidence-mix weights** — bias `type_weight` per evidence kind (trust structure/human vs.
  surface history/inference). The knob that makes multi-source data legible.
- **`role` presets** — named bundles (e.g. `reviewer` = strict + structure/human; `explorer` =
  low floor + history/inference-friendly). Design's "role is sugar over the other knobs."

**Then make it tangible:**
- **Live retune in the TUI** — proposed keys: `[` / `]` lower/raise confidence floor, `r` cycle
  role presets, repaint live so you *watch* columns reorder on a real repo.
- **CLI flags** — `--role`, `--strict`/`--floor` on `explore`/`walk` for the non-interactive path.

**Open choices to settle when resuming:**
1. Scope — all three core knobs + live retune at once, or core first (floor + evidence-mix +
   role) then live retune as a follow-up? (Lean: core first, proven by goldens, then one keybind.)
2. Live-retune keybindings (`[` `]` `r` proposed).

## 9. Roadmap beyond knobs (not committed)

- **Persistence** — accreting on-disk log/graph (hügel "the mound persists").
- **Event log underneath** — when agent undo / live+frozen snapshots are wanted (hugel3 pattern).
- **Agent provider** — the guiding star: agent edits/chats/proposed-diffs as observations;
  `proposed_change` as a first-class object; the session reflected in columns.
- **hügel-Pile provider** — read an existing hugel knowledge graph as a source.
- **UI gems** — pastel / tty-reader / unicode-display_width if the terminal becomes a keeper.
- **Graph-scene (neighborhood) view** — the canvas counterpart to columns (DESIGN §7.2).
