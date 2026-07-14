# hcolumns — Status & Handoff

**Updated:** 2026-07-14 · **Branch:** `main` · **Tests:** 205 examples, 0 failures · **Runtime deps:** none required (`ruby-mysql` is a *soft* dep — without it only the beads provider is off)

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
> cross-front-end contract lives in the data, not any renderer. The terminal stops being the only probe →
> **content tabs**: a node's *contents* are now a facet beside its relations — a file's **source**, a
> commit's **diff** (`git show`, +/- colored in the browser), a run's **output** — derived views read
> from disk/git on demand, never folded into the graph. Same Mode/tab machinery, so the TUI gets them too →
> **live web** (`hcol serve session --live`): the browser watches the agent work — columns grow and the
> auto mode flips editing→testing→reviewing as the Feed releases events. Done by *request-driven polling*
> (a `/state` version the client polls; the server pumps due events per request), not threads/SSE — true
> to the single-writer model; SSE is the upgrade paired with the real async producer →
> **persistence (JSONL)**: the event log serializes one-event-per-line to disk and replays on load
> (`hcol save session f.jsonl` → `hcol walk f.jsonl`), so a session survives a restart — the hügel "the
> mound persists" step. A symbol/Time-faithful codec keeps replay-from-disk *behaviorally* identical to
> in-memory (`:phase` stays a Symbol, so phase-biasing still fires on a reload) →
> **real async producer (out-of-process log-tail)**: a *separate process* appends events to an
> append-only JSONL log in real time (`hcol produce session f.jsonl`) and a consumer *tails* it
> (`hcol walk/serve f.jsonl --live`) — the columns grow as lines land. Concurrency lives **between
> processes** (the file), so the in-memory log stays single-writer and needs **no mutex**: the log-is-truth
> reframe dissolves the thread-safety the STATUS kept promising rather than paying for it. `TailReader`
> duck-types the `Feed` (release/log/done?), so Cascade + Web::App drive it unchanged; a live log is also
> a valid snapshot (same format, `eof` marker skipped). Verified two-process: the phase advances
> editing→testing→reviewing under a tailing consumer →
> **SSE (push, lock-free)**: the file-tail web serve (`serve f.jsonl --live`) now *pushes* over
> `text/event-stream` instead of the `/state` poll. The server goes thread-per-connection (a long-lived
> `/events` stream can't share the single-threaded accept loop), and each connection projects its **own**
> tail of the shared read-only log — so concurrent connections share no mutable state and need **no lock**
> (layer 17's log-is-truth property extended to many in-process readers). Verified over real sockets: the
> stream pushes version bumps 3→…→20 then `done:true`, and `/panel` serves *concurrently* while `/events`
> is held open. The in-memory `Feed` demo (`serve session --live`) stays on `/state` polling →
> **git exploration — per-line blame (refocus)**: priority shifted back to *exploring data sources*
> (git/fs) over the live-agent arc, sharpening the **clients** and the server data behind them. A file in a
> git repo gets a **`blame` tab**: each line tagged with the commit that last touched it (vim-fugitive
> style), every line a focusable item → a **`CommitFile`** node → its **file-scoped diff**, with **ZOOM OUT**
> to the full commit (unscoped diff + history). The whole loop — open file → blame → jump to the commit
> that changed a line → diff → zoom out — walks on the existing git substrate. Both clients rendered for it
> (web: sha column · code · author-in-dock; TUI: full-width dock reads the blamed line + its commit) →
> **beads provider (the plan layer IS the beads DB)**: the project's `bd` issue database walked as columns —
> repo root → `HAS_BEADS` → index → each bead; a bead's dependency rows become typed edges (`HAS_CHILD`/
> `CHILD_OF`, `BLOCKS`/`BLOCKED_BY`, custom kinds upcased) at `structure` 1.0, its file links become
> `TOUCHES` onto real `fs.path` nodes (metadata list → `agent`, prose-scraped path → `inference`) so a walk
> descends bead → file → blame → commit. Read via a **direct MySQL-wire connection** to the dolt
> sql-server (hcolumns as an active *client*; endpoint resolved from `.beads` state, never assumed), a
> `bead` facet renders the issue body, and the repo now dogfoods its own tracking (`bd`, prefix `hc`,
> local shared server :3308) →
> **node flags (the first interaction event)**: the user's up/down/exclude/clear judgment on a node is a
> `:flag` **event** — folded beside the evidence, never into it. Flags **bias the lens score** (Charris's
> call: opinion layer only; confidence keeps reporting the untouched truth, the rank reason shows
> `⚑down (charris)`, the inspector still shows excluded edges). Keys in both clients (`+ - x u`;
> web via `/flag`), `hcol flag <path> <level>` for bulk, and the first **accreting on-disk log**:
> flags append to `.hcolumns/flags.jsonl` as they happen and replay into the next walk — a judgment
> made today shapes tomorrow's columns. Real walks are now log-backed (providers record as they expand).
>
> **Pick up next (one of):**
> **source-at-commit facet** (`hc-48p` — now dogfooded: its `metadata` file list lights up the reverse walk) ·
> **real external agent** appending to the log (`hc-gzj` — converges with beads via issue `metadata` file
> lists, which now feed the reverse walk *and* which the agent bridge would write) · **planner facet polish**
> (a `bead` facet that foregrounds acceptance-criteria/blocker chains; a status-glyph legend) · **branch/history
> browsing polish** · **shareable cascade-state URLs** · **goal biases *ranking*** (the "soil" step into the
> tuner). The beads provider arc (slices 1–3) is complete: forward walk, reverse walk, ready/blocked, planner
> lens. The backlog now lives in beads itself (`bd list`; `hcol walk .` → the beads index). Trade-offs in
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
| `b891289` | **23** — **beads slice 3: ready/blocked views ("what can I start now")**. The planner's first question, answered by the DB's own computation. bd ships `ready_issues` and `blocked_issues` as **SQL views** (ready = open with no active blocker; blocked = an open issue blocks it), so hcolumns reads the DB's answer rather than re-deriving the dependency math — the active-client posture. The Beads **index** node now hangs two overlay edges beside `HAS_BEAD`: `HAS_READY` → each bead the ready view returns, `HAS_BLOCKED` → each blocked one (`Client#ready`/`#blocked`, P-then-id ordered, bounded `MAX_BEADS`). The same bead node carries multiple edges (it's both "a bead" and "ready"), exactly as the repo root carries `HAS_BRANCH`+`HEAD` — an empty view just omits its group (blocked is empty on our repo today, so no `HAS_BLOCKED` shows). The **planner lens** floats `HAS_READY` (1.9) above the full `HAS_BEAD` list (1.6), so standing on the index the first group *is* the startable work. The views are 1.x-only; on an older DB a view query rescues to `[]` (the overlay just vanishes — the schema guard is what signals the version gap). 5 specs (40 in the beads/lens files, 205 total); live-verified: the index's `HAS_READY` is exactly `bd ready` (hc-48p, hc-gzj), `HAS_BLOCKED` empty like `bd blocked`. |
| `b291ca3` | **22** — **beads slice 2: reverse walk + planner lens + status glyphs + schema guard**. The plan layer becomes *navigable as a plan*, and the walk closes back on itself. **(1) Reverse walk (file → beads)** — `recognizes?` now fires on *any* real file under the beads root, and expanding one adds `TOUCHED_BY` edges to every bead that names it, mirroring the forward `TOUCHES` with the same honesty split (`:agent` for a `metadata` file list, `:inference` for a path scraped from prose). The lookup is a **cached reverse index** (`abs path → [{row, kind}]`), built lazily on the first file expansion from **one bulk query** (`reverse_source`, bounded `MAX_BEADS`) and held for the Workspace — the ruby-const-index pattern, so only the first file pays. A file no bead names simply adds no edges. So a walk now runs bead → file → blame → commit *and* file → the beads that touch it. **(2) Planner lens** (`lenses/planner_lens.rb`, `--role planner`) lifts the plan families (`HAS_BEADS`/`HAS_BEAD`, the dependency web, `TOUCHES`/`TOUCHED_BY` — the reverse edge highest, so from a file the beads surface first) and dims filesystem/code/history noise; the agent's `metadata` word is mixed a touch above prose. **(3) Status → glyph** — a bead carries its lifecycle as the same glyph `bd` uses (`○◐●✓❄`) in its display name, so every renderer (TUI, web, `bead` facet) shows the plan's shape at a glance. **(4) Schema-version guard** — `connect` reads `schema_migrations` once and warns if the DB is newer than the `KNOWN_SCHEMA=49` this provider maps (the lesson of the `depends_on_id`→`depends_on_issue_id` rename); a missing table = pre-1.x, read best-effort. 7 new specs (35 in the beads/lens files, 200 total); live-verified against the shared dolt server (:3308): `client_for` connects, `schema_version` reads 49 (no false warning), `reverse_source` round-trips the live schema, planner lifts `HAS_BEADS` over `CONTAINS`, glyphs render. No live `TOUCHED_BY` edges *yet* — no current bead names an in-repo file (all `metadata` is `{}`); dogfooding a file association is the demo. |
| `87c58de` | **21** — **node flags: uprank/downrank/exclude as events, biasing rank only**. The feature Charris asked for after `.beads/interactions.jsonl` noise: flag any node and the judgment follows it everywhere. Two decisions shape it (his calls): **(1) flags are a bias layer** — `Lens#bias` multiplies the *score* (`up` ×1.5, `down` ×0.4), `exclude` hides at build time; edge **confidence is never touched**, the rank reason carries the visible `⚑level (by)`, and the details facet still shows excluded edges (opinion ≠ deletion). **(2) flag-as-event with the log plumbing** — a `:flag` event kind (the first *interaction* event; payload a plain hash, last-flag-wins so `:clear` is the undo), folded by `Graph#apply_flag` beside nodes/edges, replayed by `EventLog#fold`/`project`. **`FlagStore`** is the first accreting on-disk log: each flag appends one JSONL line to `.hcolumns/flags.jsonl` (Persistence codec, so `:level`/Time survive) and replays into the next session's graph — deliberately flags-only (provider observations re-derive from the world; persisting them would double-fold confidence). Real CLI walks now run a **log-backed graph** (the 2b seam, finally used for code) with the store attached. Driven from all three surfaces: TUI keys `+ - x u` → `Cascade#flag_selected` (re-ranks the walked path live), web `/flag?id=&level=` + the same keys on the selected item (re-fetches open columns), and `hcol flag <path> <level>` for bulk/scripted flagging. 10 specs; live-verified: `hcol flag Gemfile.lock down` from one process sinks it (⚑ visible, bar still 1.00) in a fresh `explore .`, exclude/clear round-trip. |
| `22a9722` | **20** — **beads provider: the plan layer is the beads DB**. `Providers::Beads` walks a project's `bd` issue database (Yegge's beads, dolt-backed) as columns: repo root → `HAS_BEADS` → a `Beads` index → `HAS_BEAD` per issue (bounded `MAX_BEADS`, closed ranked last); a `Bead`'s dependency rows map to typed edges — `parent-child` → `HAS_CHILD`/`CHILD_OF`, `blocks` → `BLOCKS`/`BLOCKED_BY`, unknown kinds upcased — all `structure` 1.0 (declared facts in the DB). File links are two-tier by honesty: a `metadata` JSON file list is the agent's word → `TOUCHES` at `agent` (0.7); a path scraped from description/design prose → `inference` (0.3); both land on real `fs.path` nodes so the walk continues into source/blame/git. **Integration posture (decided with Charris): direct MySQL-wire client of the dolt sql-server** — pure-Ruby `ruby-mysql` as a *soft* dependency (`available?` gates on `require`; core stays zero-dep), one cached connection per beads root shared with the new `bead` content facet (issue body: description/design/acceptance/notes). Endpoint **resolved from repo state** (`.beads/metadata.json` database name; `config.yaml` shared-server flag → shared or repo port file), never assumed — the lesson of the orphaned-DB incident. A dead server warns + drops the connection (heals on the next walk), never crashes the cascade. Repo now **dogfoods its own tracking**: `bd` prefix `hc` on the local shared dolt server (:3308), the epic/slice beads carry the provider's own design notes. Specs run against a fake client (the `Client` duck-type), 15 examples; live-verified: `hcol explore .` shows `HAS_BEADS`, the epic column renders `HAS_CHILD`/`RELATED`/`TOUCHES`, the facet renders the body. |
| `553663c` | **19** — **git exploration: per-line blame → file-scoped diff → zoom-out** (vim-fugitive-style). A **refocus on exploration** (git/fs as the subject) over the live-agent arc. A file in a git repo gets a **`blame` tab** (`BlameMode`): one `git blame --porcelain` call tags each line with the commit that last touched it; every line is a *focusable item* whose target is a new **`CommitFile`** node (that commit's change to *this* file). Descend a line → its **file-scoped diff** (`git show sha -- path`, auto mode), carrying two **ZOOM OUT** items — **▲ full commit** (→ the materialized `Commit`, the whole unscoped diff + `PARENT`/history) and **▤ current file**. So the whole fugitive loop — open file → blame → jump to the commit that changed a line → scoped diff → zoom out — is walkable, mostly on the existing git substrate (commits/branches/diffs were already there). `GitDiffMode` broadened to `Commit`+`CommitFile` (scopes on the node's `:path`). The one rule bent: `BlameMode` **materializes** the `CommitFile`/`Commit` nodes its lines point at (a lightweight expansion — nodes, not a per-line edge explosion), the one place a facet writes to the graph. Cheap `Git.in_repo?` (upward `.git` walk, no subprocess) gates the tab. **Both clients polished**: the web renders blame fugitive-style (muted sha column · code, wider column, author/date in the dock) and the TUI uses the full-width dock to read the blamed line + its commit (sha · author · date · summary). Shared `Git.commit_node`/`commit_file_node`/`blame`/`parse_blame`/`show(path:)`. 6 specs. |
| `9db3af8` | **18** — **SSE: push the tail to the browser (lock-free)**. The file-tail web serve stops *polling* `/state` and *pushes* over `text/event-stream`. The load-bearing consequence: a long-lived `/events` stream can't share the single-threaded accept loop, so the server goes **thread-per-connection** — and to stay lock-free (the choice made *with* Charris), each connection builds its **own** `App` tailing the shared read-only log (`Server.new(app_factory:, streaming: true)`), so a stream + concurrent `/panel` fetches share no mutable state and need no mutex (layer 17's log-is-truth property extended to many in-process readers; the `/panel` cost is re-folding the log per request, negligible at demo scale). New `/events` route (held open, pushes `{version, done}` whenever the log grows, closes on `eof`); `stream_events` bypasses the pure `respond` router (which stays `[status,type,body]` for the short routes). Client gains a `STREAM` flag → `EventSource('/events')` in place of the 700ms poll, same reaction (re-fetch open columns on a version bump, stop on done). The in-memory `Feed` demo (`serve session --live`) stays single-threaded on `/state` polling. Non-streaming serve byte-identical. Verified over real sockets (version 3→…→20 then done; `/panel` concurrent with an open stream). 3 specs. |
| `fee683d` | **17** — **real async producer (out-of-process log-tail)**: the live demo's producer stops being a wall-clock-*polled* `Feed` and becomes a genuinely separate **process**. `hcol produce <session\|sessions> f.jsonl` (`LogProducer`) replays the timed script into an append-only JSONL log in real time — the way a live agent would append events as it works. `hcol walk f.jsonl --live` / `serve f.jsonl --live` attach a **`TailReader`** that follows the file: each `release` reads the bytes appended since last call, splits complete lines (a half-written trailing line stays buffered), folds each into the projection, and flips `done?` on an `eof` marker. It **duck-types the `Feed`** (`release(elapsed, into:)`/`log`/`done?`), so `Cascade#tick` and `Web::App#pump` drive it unchanged — `elapsed` is ignored (events arrive on their own, not "when due"). The load-bearing reframe: concurrency lives **between processes**, mediated by the append-only file, so the in-memory `EventLog` stays single-writer and needs **no mutex** — the thread-safety the STATUS kept promising was only ever needed if you insisted on one shared in-memory log. A live log is also a valid snapshot (same JSONL; `eof` skipped by `load`), unifying layers 16↔17. Shared `Persistence.line_for`/`parse_line`/`eof_line`. Verified two-process (producer + tailing consumer): the phase advances editing→testing→reviewing and `done?` trips on eof. 7 specs. |
| `e5977b8` | **16** — **persistence (JSONL)**: the event log serializes to disk (one JSON object per line, seq order = replay order) and replays on load — the hügel "the mound persists" step. `Persistence.dump/load` + `hcol save <session\|sessions> f.jsonl`; a `.jsonl` path to `explore/walk/serve/json` reloads it (graph re-projected from the log, root = the first `:node` event). The load-bearing piece is a **symbol/Time-faithful `Codec`**: JSON drops Ruby Symbols (edge/evidence kinds, a Session's `:phase` — a *string* there silently kills phase biasing) and Time (`observed_at`, drives decay). All-symbol-keyed hashes stay readable plain objects and re-symbolize on load; a mixed/string-keyed hash (a diff's `hunks`, keyed by file path) falls back to a tagged `$map` pair-list so key *types* survive; symbol values → `$sym`, Time → `$time` (via `to_r`, exact instant). So replay-from-disk is *behaviorally* identical to in-memory — verified: a reloaded frozen session's `:phase` is still `:reviewing`, so its auto mode resolves to `reviewer`. `session_context` now keys on the `:phase` property (not the magic arg `"session"`), so a loaded session drives modes too. `sessions_graph` gained an optional `graph:` seam so a log-backed snapshot captures every event. 9 specs. |
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
| `f0be3a0` | **15** — **live web (request-driven)**. `hcol serve session --live` (and `sessions --live`): the browser watches the agent session grow, the web analogue of `walk session --live`. `Web::App` gains an optional `feed:` + injectable `clock:`; `pump` releases due events (`elapsed = clock − start`) into the graph — single-writer, **per request**, the web echo of `Cascade#tick`. New `/state` route returns `{version, done}`; the server pumps before answering *any* request, so a poll or a descend both see the current graph. The client tracks its open columns, polls `/state` ~700ms, and on a version bump **re-fetches every open column in place** — so a column grows new items and an auto-mode column re-resolves its tab as the phase moves (pinned tabs preserved). A pulsing "● live" badge; "✓ session complete" stops the poll on `done`. **No threads/SSE** — true to the single-writer posture (the `EventLog` thread-safety + SSE belong with the real async producer). Non-live path byte-identical (`feed` nil ⇒ `live?` false ⇒ no pump, `LIVE=false`). 6 specs (injected clock: growth, phase flip, done, `/state`); server-verified the column grows + auto flips reviewer at t≈6s. |
| `be4b56c` | **14** — **content tabs (file source · git diff · run output)**. A node's *contents* become a facet beside its relations: `SourceMode` (a file's text, numbered + bounded), `GitDiffMode` (a `Commit` → `git show --stat -p`, bounded), `OutputMode` (a `TestRun`/`LogLine` → its captured `:output`, falling back to the summary line). Each `applies?` guards its tab, so it only shows when there's real content — a demo node whose path isn't on disk just doesn't get `source`. **Derived views, never folded into the graph** (file bytes/diffs are volatile rendering against the live fs/git, not substrate). I/O lives in the providers (`Filesystem.read_lines` w/ size+encoding guard, `Git.show`). Resolver `POLICY`: `source` on file types, `gitdiff` auto on `Commit`, `output` on `TestRun`/`LogLine`, new `Doc`/`File` entries. Web client colors diff `+`/`-`/`@@`/meta lines and scrolls content both axes. AgentSession s1 enriched with real test/log output. Same Mode machinery → the TUI gets the tabs too. 10 specs; server-verified all three. |
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
flag_store.rb      the accreting on-disk log for human judgments: each flag appends one JSONL line
                   to .hcolumns/flags.jsonl, replay() folds them into the next session's graph.
                   Flags-only by design — provider observations re-derive from the world; persisting
                   them would double-fold probabilistic confidence on reload
persistence.rb     JSONL on disk: dump(log,io)/load(io) one event per line; root_id = first :node.
                   Codec round-trips what JSON drops — Symbols ($sym / plain object for all-symbol keys /
                   $map pair-list for mixed keys) and Time ($time via to_r). Node/Observation <-> Hash.
                   line_for/parse_line/eof_line = the per-line seam shared with the tail/producer
tail_reader.rb     consumer of an out-of-process producer: follows an append-only JSONL log a separate
                   process writes, folding new lines into a projection as they land. Buffers a partial
                   trailing line; eof -> done?. Duck-types Feed (release/log/done?) — no mutex (the file
                   is the only shared state; the in-memory log stays single-writer)
log_producer.rb    the producer: replays a timed [{after:,kind:,payload:}] script into a JSONL log in
                   real wall-clock time (injected clock/sleeper for deterministic tests), then an eof
                   marker. `hcol produce session f.jsonl` in one terminal, `walk f.jsonl --live` in another
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
content_modes.rb   content facets (a node's contents, not relations; derived views, not graph-folded):
                   SourceMode (file text, numbered/bounded), BlameMode (per-line blame; each line an item
                   -> a CommitFile; materializes those nodes), GitDiffMode (Commit -> full git show, or a
                   CommitFile -> file-scoped diff + ZOOM OUT items), OutputMode (TestRun/LogLine ->
                   captured :output), BeadMode (a bead's body: description/design/acceptance/notes, read
                   live from the beads DB via the provider's shared client). Each applies? gates its tab
                   to real content
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
  beads.rb              the plan layer: a project's beads (bd/dolt) issue DB as columns. Direct
                        MySQL-wire client (soft dep ruby-mysql; available? gates), endpoint resolved
                        from .beads state (shared-server flag + port files). root → HAS_BEADS → index
                        → HAS_BEAD; deps table → HAS_CHILD/CHILD_OF, BLOCKS/BLOCKED_BY (+ upcased
                        custom kinds) at structure 1.0; metadata file list → TOUCHES @ agent, prose
                        path → TOUCHES @ inference, onto real fs.path nodes. Client duck-type
                        (index/deps_for/issues_by_ids/body) = the spec seam
  git.rb                two-faced: file → CO_CHANGED_WITH/CHANGED_BY; repo root → HAS_BRANCH/HEAD,
                        Branch → POINTS_AT, Commit → PARENT/CHANGED/AUTHORED_BY. Bounded as before.
                        Also: blame(repo,path) (--porcelain, per-line sha+author+summary) + parse_blame;
                        show(repo,sha,path:) scopes a diff to one file; in_repo? (cheap .git walk);
                        commit_node/commit_file_node builders shared with the blame facet
  ruby_code.rb          DEFINES/DEPENDS_ON/REFERENCES via Ripper AST; nested Analyzer walks the
                        sexp keeping a module/class scope stack; lazy cached repo const index
                        (MAX_INDEX_FILES=2000) backs cross-file REFERENCES + DEFINED_IN back-edge
web/                    the second front-end — a renderer peer that emits data, not terminal text:
  serializer.rb         Panel/Node/Section/Item -> JSON-able Hash (symbols/nested props made JSON-safe)
  app.rb                node id (+ optional mode) -> serialized panel + resolver-ranked modes, using the
                        SAME ModeResolver as the TUI; one stateful Workspace held across calls = descend.
                        Optional feed: + clock: makes it LIVE: pump releases due events per request
                        (elapsed = clock−start); version/done? drive the client poll (the web Cascade#tick)
  server.rb             zero-dep raw-TCPServer HTTP. pure respond(method,path,query) router (socket-free
                        testable, pumps a per-request app first) + socket loop; `/` = inline columns client,
                        `/panel?id=&mode=` = JSON, `/state` = {version,done}, `/events` = SSE stream. Two
                        modes: Server.new(app) = one shared app, single-threaded (static / Feed live, /state
                        poll); Server.new(app_factory:, streaming:true) = thread-per-connection, a fresh app
                        (own log tail) per connection = lock-free, and /events pushes {version,done} as the
                        log grows. Client: STREAM flag picks EventSource('/events') over the /state poll
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
# per-line blame (vim-fugitive style): open a file, Tab to `blame`, descend a line
./exe/hcol walk lib/hcolumns/cli.rb          # Tab to the `blame` tab; each line → the commit that touched it
                                             # descend a line → file-scoped diff → "full commit" row zooms out

./exe/hcol explore . --role git              # lift commits/branches, dim files
./exe/hcol explore lib/hcolumns/cascade.rb --role reviewer   # strict: structure-first, weak edges hidden
./exe/hcol explore . --role explorer --floor 0.6             # speculative + a confidence floor

# flags — your judgment as events; biases rank, never confidence; persists across walks
./exe/hcol flag Gemfile.lock down     # sink it in every column (⚑down, bar unchanged)
./exe/hcol flag AGENTS.md exclude     # hide it from lens columns (details facet still shows it)
./exe/hcol flag AGENTS.md clear       # the undo — last flag wins
./exe/hcol walk .                     # + - x u flag the selection live; .hcolumns/flags.jsonl accretes

# beads — the project's issue DB as columns (needs the shared dolt server; bd dolt start)
./exe/hcol explore .              # …now also HAS_BEADS → the beads (hc) index
./exe/hcol walk .                 # descend into a bead: children/blockers/TOUCHES (⚑ status glyph), Tab → `bead` body
./exe/hcol explore . --role planner          # the plan facet: lift beads/deps, dim code/filesystem noise
./exe/hcol explore lib/hcolumns/cli.rb --role planner   # reverse walk: TOUCHED_BY → the beads that name this file
./exe/hcol walk . --role planner             # index column leads with HAS_READY (bd ready) then HAS_BLOCKED, HAS_BEAD

# the web front-end — same columns, in a browser (zero runtime deps)
./exe/hcol json src/orders.rb                # the node's panel + ranked modes as JSON (the data contract)
./exe/hcol serve .                           # GET / = columns client, /panel?id=&mode= = JSON; --port N
./exe/hcol serve session                     # the agent-session route, walkable in a browser; phase drives auto mode

# persistence — the mound persists (JSONL snapshot + reload)
./exe/hcol save session /tmp/s1.jsonl        # dump the session's event log to disk (one event per line)
./exe/hcol walk /tmp/s1.jsonl                # reload it: the graph re-projects from the log, walkable
./exe/hcol json /tmp/s1.jsonl                # …reloaded phase (:reviewing) still drives the auto mode -> reviewer

# real async producer — two processes meeting only at the file (no threads, no mutex)
./exe/hcol produce session /tmp/live.jsonl   # terminal 1: a separate process appends events in real time
./exe/hcol walk /tmp/live.jsonl --live       # terminal 2: tail it — the cascade grows as lines land
./exe/hcol serve /tmp/live.jsonl --live      # …or in a browser (phase drives the auto mode live)
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
- **Live tail is poll-based, and forgiving-not-bulletproof** — `TailReader` reopens the file each
  `release` and reads from a byte offset (`IO.select` can't truly block on a regular file, so the loops
  still tick at `POLL_INTERVAL`). It buffers a partial trailing line, but does **not** handle log
  *rotation/truncation* (if the file shrinks below the offset it silently reads nothing). Fine for the
  single-writer append-only demo; a real long-running tail would want inotify/rotation handling.
- **Streaming server is thread-per-connection, uncapped** — the file-tail `serve --live` spawns a thread
  per connection (needed so a long-lived `/events` stream doesn't block `/panel`), with no pool/limit, and
  each `/panel` request re-folds the whole log into a fresh projection (lock-free, but O(log) per request).
  Both are fine for a single-user probe; a real deployment would want a thread cap + a shared read-through
  cache. The non-streaming serve (static / `Feed` live) is unchanged: single-threaded, one shared app.
- **The producer is still the demo script** — `hcol produce` replays `AgentSession`'s timed script; a
  *real* external agent appending to the log (via a hook/bridge) is the next step (the transport — a
  file — is already proven). And the pull providers (fs/git/ruby) still don't record into a log, so only
  the agent-session demo is snapshottable/tailable today; a real code walk isn't yet.
- **Beads provider needs a reachable server** — reads want the dolt sql-server up (`bd dolt start`);
  a dead server degrades gracefully (warn + no beads edges) but there's no auto-start. No schema-version
  guard yet (a DB written by a much newer bd could present unknown columns — `deps_for` already hit one
  rename in the wild, `depends_on_id` → `depends_on_issue_id`). Prose path-scraping is a blunt heuristic
  (it will happily TOUCH `.beads/dolt-server.port` if your notes mention it) — honest at `inference` 0.3,
  but a `planner` lens may want to dim it. Index bounded at `MAX_BEADS=200`, no closed-issue paging.
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

- **Sharpen the `debugging` phase (content facets now exist).** Layer 14 added `source`/`gitdiff`/
  `output` facets, so a `TestRun`/`LogLine` already shows its captured output. What's *not* done: a
  facet that **foregrounds the failing assertion** (vs the whole run), and wiring a content facet into
  `PHASE_PREFERENCE[:debugging]` so the debugging phase auto-opens output/diff rather than `details`+
  `git`. Both are small (a `Mode#panel` tweak + a resolver entry). Also open: a file's *latest* diff in
  git-context (`gitdiff` currently applies to `Commit` only — a SourceFile version needs a cheap
  repo-root signal so `applies?` stays subprocess-free).
- **Goal biases *ranking* (the deep one — the hugel-v1 "soil").** Phase reorders *modes* today; the
  next escalation is a goal/relevance term so that *within* a column, goal-relevant entries rank
  higher. This reaches into the tuner/score (the `session:` seam currently only reaches the
  resolver). Load-bearing — work the use case through first.
- **Goal/phase reaching the multi-session index.** The index walk passes `session: nil`; deriving
  "which session am I within" from the trail would let phase biasing apply there too.

- **Persistence — accreting on-disk log (layer 16 follow-on).** Snapshot dump/load is built
  (`hcol save` → JSONL → reload re-projects). Remaining: an *append-as-you-go* log file the
  `EventLog` writes to per event (not a whole-log dump), so a session accretes on disk as it runs and
  a crash loses nothing — the true hügel "the mound persists". Pairs naturally with the real async
  producer (both touch the append path). Also open: let the pull providers (fs/git/ruby) record into
  a log so a real *code* walk is snapshottable, not just the agent-session demo.
- **Undo / `:retract`.** The third event kind is designed-in but unimplemented — append a counter-
  event referencing an observation's seq, recompute just that edge (local; the edge keeps its
  observation list). This is the *other* feature that justified the log (agent reject/undo); it
  also unlocks frozen-snapshot-at-seq-K (fold events `seq ≤ K`).
- **Real async producer — DONE out-of-process (layer 17).** A separate process (`hcol produce`) appends
  to an append-only JSONL log; `TailReader` follows it (`walk/serve --live`). Concurrency is between
  processes, so no mutex was needed — the "thread-safety on `EventLog#append`" this bullet used to
  demand turned out to be avoidable by making the *file* the shared state. **SSE is also DONE (layer 18)**
  — the file-tail serve pushes over `/events`, thread-per-connection, each connection lock-free on its own
  log tail. Remaining follow-ons: a **real external agent** as the producer (a Claude Code hook or a
  small bridge appending events) in place of the demo script; and, if an in-process producer is ever
  genuinely wanted, *that* is when the mutex/thread-safety question returns — deliberately not paid for now.
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
- **Deepen the web client (layers 13–15 follow-ons).** Renders, descends, content tabs, grows live
  (layer 15 poll), **and now pushes over SSE** (layer 18, the file-tail serve). Remaining, each localized:
  **shareable cascade state** — encode the trail in the URL so a walk is linkable; **the dock** — the
  client shows `detail`/`reason` but not the full-width hunk dock the TUI has; **pin/Tab parity** — a
  pinned tab survives a live refresh but not yet a re-descend; **SSE for the `Feed` demo** — `serve
  session --live` still polls (the in-memory timeline isn't per-connection projectable); **thread hygiene**
  — the streaming server is thread-per-connection with no cap (fine for a probe, not for many clients).
  None are load-bearing; they deepen the probe. The data contract (`Serializer`) is the part that's locked.
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
