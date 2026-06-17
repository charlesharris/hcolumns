# hcolumns — Status & Handoff

**Updated:** 2026-06-17 · **Branch:** `main` · **Tests:** 79 examples, 0 failures · **Runtime deps:** none (rspec is dev-only)

This is the "where we are / how to resume" doc. For the *why* see [`DESIGN.md`](DESIGN.md)
(the charter); deeper decision history lives in the project memory.

> ✅ **All work is committed on `main`** (working tree clean). Layers 5–7, the lens refactor, the
> confidence rework, adaptive width, `install.sh`, and the new agent-session prototype were
> committed 2026-06-17 as a clean per-layer sequence. The open thread now is the **live/push fork**
> the agent provider surfaces — see [§8](#8-next-up--open-threads).

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
| `21b4e89` | **5** — **ruby_code** provider (Ripper, stdlib): `DEFINES` (file→Class/Module, Class→methods), `DEPENDS_ON` (require/require_relative), `REFERENCES` (const→definition, resolved via a lazy cached repo const index). Columns now descend *into* code, not just files. |
| `724af43` | **6** — **tuner knobs + lenses**: confidence `floor` + per-evidence-kind `evidence_mix` on the Tuner; `Lens` = tuner + relation-family emphasis + optional `scope` (only:/hide:). Live retune in the TUI (`r` cycle lens, `[`/`]` floor) + CLI `--role`/`--floor`/`--strict`. "Same graph, different surface", switchable. |
| `212b05b` | **7** — **git structure** (extends the git provider): repo root → `HAS_BRANCH`/`HEAD`; Branch → `POINTS_AT`; Commit → `PARENT`/`CHANGED`/`AUTHORED_BY`. The repo root is the "git headspace" entrypoint; the `git` lens lifts these families. Authors unify with file `CHANGED_BY`. |
| `724af43` | refactor — `Lens` split into a base engine + one-file-per-type subclasses under `lenses/` (reviewer/explorer/git/filesystem), name→class registry. Adding a lens = drop a file + register. |
| `0afb16b` | fix — **confidence model** reworked to two modes. **Deterministic** evidence (filesystem containment, AST defs, resolved requires) is verifiable ground truth → confidence **exactly 1.0**, `confirmed` maturity, no decay/mix. **Probabilistic** evidence (history/inference/convention/behavior/human) folds via **noisy-OR over per-occurrence reliability** — accrues with evidence, decays with age. Replaces the old sum-then-squash where a lone fact read only 0.63. Added a `convention` kind; reclassified the naming-rule PAIR off `structure` (it's a heuristic). Goldens regenerated. |
| `f1e3728` | **adaptive TUI width** — `CascadeText.render(cascade, width:, height:)`: shows the rightmost columns that fit (older scroll off left, `‹` marker, full trail kept in breadcrumb), grows columns to fill (MIN 16…MAX 44), truncates chrome, clamps height with a `↓ +N` overflow marker. `TUI` reads `winsize` each paint (hardened against 0×0) and repaints live on `SIGWINCH`. No-width path unchanged (goldens hold). |
| `446280e` | chore — `install.sh` (idempotent build+install of the `hcol` gem; rbenv-rehashes). |
| `446280e` | **8** — **agent-as-event-source (frozen)**: an `agent` evidence kind (0.7, ~7d half-life) + `AgentSession` fixture freezing one session as a graph. The route `Session→PROPOSES→ProposedChange→TOUCHES files / VERIFIED_BY TestRun→EMITTED LogLine` walks as a cascade — the guiding-star thesis, made concrete. Deterministic `TOUCHES` (1.0) vs the agent's `PROPOSES`/`FOCUSES_ON` assertions (0.70) are visibly separated; touched files carry real `fs.path` ids so they unify with the code graph. `hcol explore/walk session`. **Still pull/frozen — no live push.** |

## 4. File map (`lib/hcolumns/`)

```
identity.rb        {scheme,key} -> obj:<hash>   (cross-source sameness is a SAME_AS edge, not a merge)
evidence.rb        7 kinds in two modes: deterministic (structure → 1.0, verifiable) vs probabilistic
                   (human .95/agent .7/behavior .6/convention .55/history .5/inference .3) + decay half-life
observation.rb     the primitive providers append; reliability(now,mix): 1.0 if deterministic, else
                   decay·kind_reliability·mix (capped <1)
node.rb            graph node (type, identity, properties)
edge.rb            DERIVED fold: confidence = noisy-OR 1−∏(1−rᵢ)^weightᵢ (a deterministic obs pins it to
                   1.0; probabilistic accrues), recency, maturity (deterministic|human ⇒ confirmed)
graph.rb           nodes + edge projection; observe() folds; edges_from/into
tuner.rb           evidence math: score = w_conf·confidence + w_recency·recency; floor + evidence_mix
lens.rb            base engine: tuner + relation_weights + optional scope; score/visible?/admits?/
                   with_floor; name→class registry (preset/cycle). Base IS the neutral :default lens
lenses/            one file per lens type (subclass overrides declarative class-level config):
  reviewer_lens.rb      strict floor + structure/human up, history/inference down
  explorer_lens.rb      low floor + history/inference up, freshness weighted
  git_lens.rb           lift commits/branches/authorship/co-change, dim files (fugitive-style)
  filesystem_lens.rb    mirror of git: lift containment/defs/pairs, dim history (also a pattern demo)
column.rb          ColumnEntry / ColumnGroup / Column   (entry score/confidence come from the lens)
column_builder.rb  outgoing edges -> lens scope+floor filter -> grouped by relation -> total order
workspace.rb       graph + providers + a swappable lens; column_for() expands lazily; the pull seam
cascade.rb         Miller traversal: frames, cursor, into/back, preview, trail; cycle_lens/adjust_floor
providers/
  in_memory_fixture.rb  demo coding-workspace graph (golden substrate)
  agent_session.rb      frozen agent-session graph: Session→ProposedChange→files/TestRun→LogLine;
                        the guiding-star route, rendered through the unchanged pipeline (no push yet)
  filesystem.rb         CONTAINS, one dir level at a time; skips hidden/.git/node_modules/...
  naming_rules.rb       source<->test PAIR by string transform (heuristic; misses flat spec/ dirs)
  git.rb                two-faced: file → CO_CHANGED_WITH/CHANGED_BY; repo root → HAS_BRANCH/HEAD,
                        Branch → POINTS_AT, Commit → PARENT/CHANGED/AUTHORED_BY. Bounded as before
  ruby_code.rb          DEFINES/DEPENDS_ON/REFERENCES via Ripper AST; nested Analyzer walks the
                        sexp keeping a module/class scope stack; lazy cached repo const index
                        (MAX_INDEX_FILES=2000) backs cross-file REFERENCES + DEFINED_IN back-edge
renderers/
  text.rb               single column (maturity glyph, confidence bar, rank reason); fixed width
  cascade_text.rb       side-by-side columns; viewport-aware render(width:,height:): clip to rightmost
                        fitting columns, grow to fill, truncate chrome, vertical clamp + overflow marker
tui.rb                  interactive driver (raw mode, arrows/hjkl, r/[/], q/Esc/Ctrl-C; CR+LF on paint);
                        reads winsize each paint (floored vs 0×0), repaints live on SIGWINCH
cli.rb                  explore / walk / nodes / help; --role/--floor/--strict lens flags; real path
                        -> indexed (filesystem+naming+git+ruby); else demo selector
```

(repo root also: `install.sh` idempotent build+install; `exe/hcol` runs from source.)

## 5. What works today

```sh
bundle install
bundle exec rspec                 # 74 examples
./install.sh                      # build + install the hcol gem (idempotent); -s skips tests

# demo graph (in-memory fixture)
./exe/hcol explore                # column for src/orders.rb
./exe/hcol explore repo/          # CONTAINS (folder-style) column
./exe/hcol nodes

# real filesystem + git + ruby, indexed lazily
./exe/hcol walk .                 # interactive cascade (arrows/hjkl; r cycle lens, [ ] floor, q quit)
./exe/hcol explore lib/hcolumns/cascade.rb   # CHANGED_BY + CO_CHANGED_WITH + DEFINES/REFERENCES
./exe/hcol explore .              # repo root: CONTAINS + HAS_BRANCH + HEAD (the git entrypoint)

# lenses — same graph, different surface
./exe/hcol explore . --role git              # lift commits/branches, dim files
./exe/hcol explore lib/hcolumns/cascade.rb --role reviewer   # strict: structure-first, weak edges hidden
./exe/hcol explore . --role explorer --floor 0.6             # speculative + a confidence floor
```

Verified end-to-end (incl. PTY-driven interactive walks of the real repo). On a real file,
git co-change even surfaces source↔test links the naming heuristic misses — multi-source
evidence covering blind spots. The reviewer/git/filesystem lenses visibly reorder and prune the
same column without recompute.

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
- **Ruby reference index** — cross-file `REFERENCES` triggers a one-time repo scan (parse every
  .rb, bounded at 2000 files) on first use; cached per Workspace, but the one un-lazy cost here.
  Resolution is by const-name suffix (shortest qname wins) — heuristic, hence `inference` evidence.
- **Ruby provider is Ruby-only** by design — other languages are future sibling providers.
- **Git-structure cost** — expanding the repo root / a commit shells out to git (branches, HEAD,
  per-commit log + name-only); bounded per node, not cached. Repo root only (subdirs don't trigger it).
- **Lens presets are hand-tuned constants** — the floor/mix/relation-weight numbers in each
  `lenses/*.rb` are judgement calls, not learned; expect to tune them as real repos exercise them.
- **Re-lensing rebuilds columns** — `cycle_lens`/`adjust_floor` re-pull every frame from the graph
  (no recompute of evidence, just re-score/regroup); fine at current sizes, watch it if columns grow.
- **No `Rakefile`** — `./install.sh` builds + installs `hcol` (idempotent); `./exe/hcol` runs from source.
- **Glyph display-width** — the cascade adapts to terminal width (clips to the rightmost columns that
  fit, grows to fill, clamps height, repaints on SIGWINCH), but still measures with `String#length`, so
  wide/ambiguous glyphs (CJK, some emoji) can mis-align by a cell. `unicode-display_width` would fix it,
  deferred with the UI gems. The static `Text` renderer (`hcol explore`) is still fixed-width.
- **`homepage` in gemspec is a placeholder**; no `LICENSE` file though gemspec says MIT.

## 8. NEXT UP — open threads

Layers 5–8 are committed; the working tree is clean. The agent-session fixture (layer 8) proves
the route walks as a cascade. **The live thread now:**

- **THE FORK — live/push vs pull-snapshot (load-bearing; decide with Charris first).** The agent
  session is the first *temporal/push* source. Every existing provider is pull (`expand` once,
  `@expanded`-guarded, static state). "Session reflected in the UI, live" means events append *after*
  a node was expanded and columns must grow — which **breaks the once-per-node cache**. That's
  exactly where event-sourcing (append + re-fold, hugel3 pattern) earns its place. The frozen
  fixture deliberately defers this. Two paths to weigh: (a) an append-driven event log under the
  read-model (the architecture-decisions "slot-in" seam); (b) re-pull/invalidate a node on demand
  without a log. Decide via the concrete use case (a session that keeps touching files mid-walk)
  before building — see the project memory on earning architecture through use cases.
- **`agent` evidence kind (0.7, ~7d) — confirm the numbers.** Added in layer 8; a judgement call.
  Open sub-question: an agent *action* is certain (it happened — event-log territory) while its
  *relevance claim* is uncertain. Layer 8 maps verifiable actions to `structure` and assertions to
  `agent`; revisit if the action/claim split wants to be first-class.
- **Real agent provider (vs the frozen fixture)** — a pull `AgentSession` provider with
  `recognizes?(Session/ProposedChange)` + `expand`, reading a real session store. Natural follow-on
  once the fork is decided (the store *is* the proto event log).
- **Scoping lens in anger** — the `only:`/`hide:` scope is built/tested but no preset uses it; a
  "session-only" lens (hide code-graph noise) is now a concrete want for the agent view.
- **Tune lens preset constants** against more real repos; consider per-lens goldens.
- **Lens label in the static renderer** — `hcol explore --role X` doesn't show the active lens.
- **Other-language code providers** — the ruby_code pattern generalizes (JS/Python sibling).

## 9. Roadmap beyond (not committed)

- **Persistence** — accreting on-disk log/graph (hügel "the mound persists").
- **Event log underneath** — when agent undo / live+frozen snapshots are wanted (hugel3 pattern).
- **Agent provider** — the guiding star: agent edits/chats/proposed-diffs as observations;
  `proposed_change` as a first-class object; the session reflected in columns.
- **hügel-Pile provider** — read an existing hugel knowledge graph as a source.
- **UI gems** — pastel / tty-reader / unicode-display_width if the terminal becomes a keeper.
- **Graph-scene (neighborhood) view** — the canvas counterpart to columns (DESIGN §7.2).
- **Decaying deterministic confidence** — a future knob: even a verified fact could lose confidence
  as the snapshot ages (the FS may have changed since we last looked). Deferred; for now a fact is 1.0.
- **Re-verification of deterministic facts** — on revisit, re-read the source so confidence stays a
  true reflection of the underlying filesystem (today expansion runs once per node and is cached).
