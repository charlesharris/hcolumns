# hcolumns — Status & Handoff

**Updated:** 2026-06-30 · **Branch:** `main` · **Tests:** 127 examples, 0 failures · **Runtime deps:** none (rspec is dev-only)

This is the "where we are / how to resume" doc. For the *why* see [`DESIGN.md`](DESIGN.md)
(the charter); deeper decision history lives in the project memory.

> ✅ **All work is committed on `main`** (working tree clean, 112 ex green). **Resume at
> [§8](#8-next-up--open-threads).**
>
> **Where we are (the arc so far):** property graph → columns → cascade/TUI → lazy providers
> (fs/naming/git/ruby) → lenses → two-mode confidence → **event log** under the read-model →
> **live agent session** (`hcol walk session --live`, the column grows as the agent works) →
> **sessions index** + **inspector** → **dynamic interface**: per-column **mode tabs** (auto by
> node type, `Tab` to cycle, resolver-ranked), the **agent's phase** reordering modes live (the UI
> follows what the agent is *doing*), a real **diff facet**, and a **full-width detail dock** for
> hunks/breakdowns → **second front-end (web)**: the Panel/Node data serializes to JSON and a
> zero-dep HTTP server (`hcol serve`) renders the *same* walkable columns in a browser — proving the
> cross-front-end contract lives in the data, not any renderer. The terminal stops being the only probe.
>
> **Pick up next (one of):** a real `debug`/`test`/`log` facet · **goal biases *ranking*** (the
> "soil" step into the tuner) · JSONL **persistence** · **`:retract`/undo** · a real async event
> producer · **deepen the web client** (live `tick` over SSE, a real cascade-state URL). Trade-offs in
> [§8](#8-next-up--open-threads); decide the load-bearing ones *with* Charris first (he earns
> architecture through worked use cases — see project memory).

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
| `446280e` | **8** — **agent-as-event-source (frozen)**: an `agent` evidence kind (0.7, ~7d half-life) + `AgentSession` fixture freezing one session as a graph. The route `Session→PROPOSES→ProposedChange→TOUCHES files / VERIFIED_BY TestRun→EMITTED LogLine` walks as a cascade — the guiding-star thesis, made concrete. Deterministic `TOUCHES` (1.0) vs the agent's `PROPOSES`/`FOCUSES_ON` assertions (0.70) are visibly separated; touched files carry real `fs.path` ids so they unify with the code graph. `hcol explore/walk session`. |
| `597c712` | **13** — **second front-end: web**. `Web::Serializer` (a renderer peer: same `Panel`/`Node` data → plain JSON-able Hashes, geometry ignored — the point being the contract is the *data*); `Web::App` (the consumer the serializer lacked: a node id → its panel + the **resolver-ranked modes**, via the *same* `ModeResolver` the TUI drives, so browser/terminal agree on tabs+auto by construction; one stateful `Workspace` held across calls = descend-as-you-go); `Web::Server` (dependency-free raw-`TCPServer` HTTP — no webrick/rack, matching the hand-rolled TUI; pure `respond(method,path,query)` router split from the socket loop so routing is socket-free testable; `/` serves an inline columns client (HTML/CSS/JS, ROOT_ID patched in), `/panel?id=&mode=` serves the JSON it fetches to render + descend). `hcol json [node]` (the contract on stdout) + `hcol serve [node] [--port]`. pty-free-verified: browser descends README→…, phase drives the session's auto mode to `reviewer`, 404 on unknown node. 15 new specs. |
| `5a39f66` | **12b** — **richer detail + full-width dock**. The selected item's detail (a diff facet's **hunk**, a details facet's edge breakdown) now renders in a **full-width dock below the cascade** (`CascadeText#dock_lines`, separator + clamp to `DOCK_MAX`, body height reserves it) — readable, not clipped to a narrow column. The right **preview column** is a navigational peek of the descend target (auto mode, `details`-facet fallback so a leaf isn't empty). Diff bodies live on the `ProposedChange` node (`properties[:hunks]`); s1 carries representative hunks (a real agent/diff provider would fill them for real). |
| `1357ea5` | **12** — **dynamic interface: agent phase drives the modes**. The auto mode follows what the agent is *doing*. A session's phase (exploring/editing/testing/debugging/reviewing) lives as a `:phase` property on the `Session` node, set by re-emitting it (an event — survives replay, shows in the inspector); `SessionContext` reads it. `ModeResolver` floats `PHASE_PREFERENCE` modes to the head, filtered by `Mode#applies?` (editing can't force `diff` onto a `SourceFile`), `:details` always kept. `Cascade` Frame gains `pinned`; `rebuild!` re-resolves *non-pinned* frames against the current phase (auto follows) and refreshes their node, while a Tab/`i`-pinned frame stays. `AgentSession` s1 emits a phase timeline (editing→testing@4s→reviewing@5.5s) by re-emitting the node. pty-verified: a descended change frame flips diff→reviewer live as the agent moves editing→testing. |
| `d6c70d2` | **11** — **dynamic interface: context-driven mode tabs**. The lens stops being one global toggle and becomes a *function of where you are*: a `ModeResolver` (keyed on node type; `session:` seam reserved for goal/phase biasing) returns a **ranked list of modes** per node — head = auto, rest = the tabs (resolver-ranked, not all-lenses). A `Mode#panel(node,ws,now) → Panel` (a rendering split into sections of headings/lines + focusable `items`); `LensMode` = the lensed column as a panel, `DetailFacet` = the inspector as a panel (the `i` modal retired — details is a tab now), `DiffFacet` = the first *renderer-carrying* facet (a `ProposedChange` as a changeset: files+churn, focus ★, ✓ status, each file descendable). `Cascade` Frame = `{node, modes, tab, cursor, panel}`; nav runs over `panel.items` (any facet); `Tab`/`r` cycle a column's modes, `i` jumps to details, `[`/`]` floor lens panels. Each column can be on a different mode at once. pty-verified on the live session. |
| `35a0a41` | **10** — **sessions index + contextual inspector**: `sessions_graph(now:)` adds a `Sessions` index node with `HAS_SESSION` to every session (one `session_events` builder drives the live script, the frozen `build`, and the index); `hcol explore/walk sessions`, plus `--live` (the newest session streams as you descend, `live_key:` leaves it a shell). `Renderers::Detail` = the inspector: node identity/props + the edge(s) relating it + the confidence math to each observation (reliability = base × decay × lens-mix, noisy-OR vs deterministic pin) + the lens score. TUI `i` inspects the selected entry; `hcol inspect <node\|path>` inspects a node in the round (all in/out edges). Session list is alphabetical, not newest-first (recency doesn't separate non-decaying structure edges) — noted follow-up. |
| `40aa07f` | **9** — **live event log (path a + option B)**: `EventLog` = append-only source of truth (seq/version/since/replay); `Graph` is a projection folded from it, and is **log-backed** (observe/add_node record when a log is attached, `apply_*` folds without re-recording, so the 5 pull providers are unchanged). `AgentSession` is one timed script: `build` folds it whole (frozen), `Feed` releases events as their time arrives (live). `Cascade#tick(elapsed)` releases due events + rebuilds; the `TUI` live loop waits on `IO.select` and repaints only when the column grew (no idle flicker; non-live path byte-identical). `hcol walk session --live` — the cascade grows under the walker (pty-verified). Producer is a wall-clock-polled script (single-writer, deterministic), not a thread. `:retract` event kind designed-in but deferred. |

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
graph.rb           nodes + edge projection; observe()/add_node() record to an optional log then
                   apply_*(); apply_* fold without recording (the replay path); edges_from/into
event_log.rb       append-only source of truth: append/version/since/fold/project(replay). Graph is
                   a projection folded from it; :node + :observe events (:retract designed-in, deferred)
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
panel.rb           what a column generalizes to: a Panel = sections of headings/display lines +
                   focusable items (the cursor's index space); PanelItem(target_id, maturity, glyph,…)
mode.rb            Mode#panel(node,ws,now)->Panel + a name->mode registry. LensMode = lensed column as
                   a panel; DetailFacet = inspector as a panel (items = the node's edges); DiffFacet =
                   a ProposedChange as a changeset (the first renderer-carrying facet)
mode_resolver.rb   node type -> ranked [Mode] (head = auto). A session's phase floats PHASE_PREFERENCE
                   modes to the head (filtered by Mode#applies?), :details always kept. Keystone of the UI
session_context.rb the session a walk sits in; reads the current phase off the Session node (event-
                   sourced via re-emitting the node). Duck-typed `phase`; nil = no biasing
cascade.rb         Miller traversal: Frame={node,modes,tab,cursor,panel}; nav over panel.items;
                   into/back, next_tab/prev_tab/show_details, adjust_floor (global, lens panels only),
                   preview_panel (auto mode), tick(elapsed) advances the live feed + rebuilds; live?
tui.rb (live)      live loop waits on IO.select(POLL); key → act+repaint, timeout → tick + repaint only
                   if the column grew (no flicker). Tab/r cycle modes, i → details tab, [ ] floor
providers/
  in_memory_fixture.rb  demo coding-workspace graph (golden substrate)
  agent_session.rb      the guiding-star sessions. SESSIONS specs → session_events (one timed builder);
                        build()=frozen single session; Feed.release(elapsed,into:)=live release into an
                        EventLog (drives `walk session --live`); sessions_graph(now:,live_key:)=a Sessions
                        index node + HAS_SESSION per session (drives `walk sessions [--live]`)
  filesystem.rb         CONTAINS, one dir level at a time; skips hidden/.git/node_modules/...
  naming_rules.rb       source<->test PAIR by string transform (heuristic; misses flat spec/ dirs)
  git.rb                two-faced: file → CO_CHANGED_WITH/CHANGED_BY; repo root → HAS_BRANCH/HEAD,
                        Branch → POINTS_AT, Commit → PARENT/CHANGED/AUTHORED_BY. Bounded as before
  ruby_code.rb          DEFINES/DEPENDS_ON/REFERENCES via Ripper AST; nested Analyzer walks the
                        sexp keeping a module/class scope stack; lazy cached repo const index
                        (MAX_INDEX_FILES=2000) backs cross-file REFERENCES + DEFINED_IN back-edge
web/                    the second front-end — a renderer peer that emits data, not terminal text:
  serializer.rb         Panel/Node/Section/Item -> JSON-able Hash (symbols/nested props made JSON-safe)
  app.rb                node id (+ optional mode) -> serialized panel + resolver-ranked modes, using the
                        SAME ModeResolver as the TUI; one stateful Workspace held across calls = descend
  server.rb             zero-dep raw-TCPServer HTTP. pure respond(method,path,query) router (socket-free
                        testable) + socket loop; `/` = inline columns client, `/panel?id=&mode=` = JSON
renderers/
  text.rb               single column (maturity glyph, confidence bar, rank reason); fixed width
  detail.rb             the inspector: node identity/props + relating edge(s) + confidence math per
                        observation (base×decay×mix, noisy-OR/pin) + lens score. entry() (TUI i) / node() (CLI)
  cascade_text.rb       side-by-side panels (tab strip per column) + a full-width bottom dock for the
                        selected item's detail (hunk/breakdown); viewport-aware render(width:,height:):
                        clip to rightmost fitting columns, grow to fill, reserve dock rows, vertical clamp
tui.rb                  interactive driver (raw mode, arrows/hjkl, r/[/], q/Esc/Ctrl-C; CR+LF on paint);
                        reads winsize each paint (floored vs 0×0), repaints live on SIGWINCH
cli.rb                  explore / walk / nodes / help; --role/--floor/--strict lens flags; real path
                        -> indexed (filesystem+naming+git+ruby); else demo selector
```

(repo root also: `install.sh` idempotent build+install; `exe/hcol` runs from source.)

## 5. What works today

```sh
bundle install
bundle exec rspec                 # 127 examples
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

# the web front-end — same columns, in a browser (zero runtime deps)
./exe/hcol json src/orders.rb                # the node's panel + ranked modes as JSON (the data contract)
./exe/hcol serve .                           # GET / = columns client, /panel?id=&mode= = JSON; --port N
./exe/hcol serve session                     # the agent-session route, walkable in a browser; phase drives auto mode
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

Layers 1–12b are committed; tree clean, 112 ex green. The **event log** (path a) and the **live
agent session** (option B) are built, and the **dynamic interface** is complete: per-column mode
tabs, agent-phase-driven auto modes, a diff facet, and a full-width detail dock. This is a natural
resume point — the north-star dynamic-interface arc is done; what's open are deepenings and the
deferred substrate work. **Pick one** (decide the load-bearing ones *with* Charris first, per
[[feedback-discuss-tradeoffs]] — present the trade-off and a worked use case before recommending):

- **A real `debug`/`test`/`log` facet.** Only `diff` exists. A `TestRun` debug facet (foreground the
  failing assertion) or a `LogLine` facet (surrounding output) would make the `debugging` phase land
  harder than today's `details`+`git` mapping. Slots in as a `Mode` subclass + `applies?` + a
  `PHASE_PREFERENCE`/`POLICY` entry — no core change. Lowest-risk, high-visibility next step.
- **Goal biases *ranking* (the deep one — the hugel-v1 "soil").** Phase reorders *modes* today; the
  next escalation is a goal/relevance term so that *within* a column, goal-relevant entries rank
  higher. This reaches into the tuner/score (the `session:` seam currently only reaches the
  resolver). Load-bearing — work the use case through first.
- **Goal/phase reaching the multi-session index.** The index walk passes `session: nil`; deriving
  "which session am I within" from the trail would let phase biasing apply there too.

- **Persistence — JSONL on disk.** The event log is in-memory; the hügel framing wants the mound to
  survive restarts (the one "upward revision from in-memory only" in the architecture memo). An
  append-only log makes this nearly mechanical: serialize each event to a line, replay on load.
  This is the natural immediate next step now that the log exists.
- **Undo / `:retract`.** The third event kind is designed-in but unimplemented — append a counter-
  event referencing an observation's seq, recompute just that edge (local; the edge keeps its
  observation list). This is the *other* feature that justified the log (agent reject/undo); it
  also unlocks frozen-snapshot-at-seq-K (fold events `seq ≤ K`).
- **Real async producer (vs the polled script).** The live demo's producer is a wall-clock-polled
  `Feed`; a real agent appends asynchronously (a thread/socket/file-tail writing to the `EventLog`).
  Swap is localized to the producer side; the consumer (TUI `tick`/`IO.select`) already handles
  "the log grew." Will want thread-safety on `EventLog#append` then.
- **Providers feeding the log.** The pull providers (filesystem/git/ruby) don't yet record into a
  log — attach a log to their graph (the 2b seam, already in `Graph`) so a real session's *code*
  context also participates in replay/undo. Not needed for the session demo; do it when undo wants it.
- **`agent` evidence kind (0.7, ~7d) — confirm the numbers**, and whether the action-is-certain /
  claim-is-uncertain split should be first-class (today: verifiable actions → `structure`,
  assertions → `agent`).
- **Newest-first session ordering.** The sessions index is alphabetical: `recency` can't separate
  the `HAS_SESSION` edges because `structure` doesn't decay (recency stays 1.0). Wants a recency
  notion driven by `observed_at` age independent of the decay curve (touches the tuner/Edge#recency);
  adjacent to the "decaying deterministic confidence" knob already in §9.
- **Inspector depth.** `DetailFacet` covers a node + its edges + confidence math. Could grow: the
  full event/seq history behind an edge (now that the log carries it).
- **Auto-mode feel.** Worth living with to judge the default picks (`SourceFile`→`default`,
  `ProposedChange`→`diff`) and the phase→mode mappings, and whether re-descending should remember a
  pinned tab (today it reopens on auto).
- **Deepen the web client (layer 13 follow-ons).** The browser front-end renders + descends but is
  static-fetch only. Natural next steps, each localized: **live** — the `walk session --live` `tick`
  needs a push channel (SSE/long-poll over the `EventLog`) so the browser column grows like the TUI's;
  **shareable cascade state** — encode the trail in the URL so a walk is linkable; **the dock** — the
  client shows `detail`/`reason` but not the full-width hunk dock the TUI has; **pin/Tab parity** —
  tabs work, but there's no pinned-tab-survives-descend like the cascade. None are load-bearing; they
  deepen the probe. The data contract (`Serializer`) is the part that's locked.
- **Scoping lens / "session-only" lens** — `only:`/`hide:` scope is built but unused by any preset;
  a session lens that dims code-graph noise is now a concrete want.
- **Tune lens preset constants**; **lens label in the static renderer**; **other-language code
  providers** (the ruby_code pattern generalizes) — all still open, lower priority.

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
