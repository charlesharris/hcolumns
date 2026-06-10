# hcolumns

Semantically-directed Miller columns — **Harris Columns** ("h-columns").

A structured, directed way to explore a **property graph**: the same data a
Neo4j-style browser holds (nodes + typed/weighted relationships + properties),
rendered as ranked, relation-grouped, **walkable columns** instead of a freeform
canvas. "Children of a folder" is just the special case where the only relation
is `CONTAINS`.

A Ruby playground for the idea. See [`docs/DESIGN.md`](docs/DESIGN.md) for the charter.

## Pipeline

```
providers append Observations            (filesystem, git, naming-rules, a human, an agent, ...)
   └─> Graph folds them into Edges        (derived confidence + maturity + provenance)
        └─> Tuner scores each edge         (re-weight, don't toggle)
             └─> ColumnBuilder groups & ranks
                  └─> a Renderer displays the column
```

Observations carry the evidence; the **column never knows** what a log line or a
trace span *is* — it only sees nodes and ranked edges. A new source is just a new
provider that appends observations.

## Quickstart

```sh
bundle install
bundle exec rspec          # golden-tested

# demo graph (in-memory fixture)
./exe/hcol explore         # the demo column for src/orders.rb
./exe/hcol explore repo/   # the CONTAINS (Miller-baseline) column
./exe/hcol nodes           # list nodes in the demo graph

# a real filesystem (indexed lazily, on demand)
./exe/hcol walk .          # interactively walk the current directory (arrows/hjkl, q quits)
./exe/hcol explore lib     # print one ranked column for a real dir or file
```

Example output:

```
▸ src/orders.rb  (SourceFile)
  ⇄ PAIR
      ● spec/orders_spec.rb        ▰▰▰▰▰  name matches spec/orders_spec.rb [structure+human]; conf 0.92
  ↔ CO_CHANGED_WITH
      ◌ src/payments.rb            ▰▰▱▱▱  changed together in 14 of 90 days [history]; conf 0.46
      · src/inventory.rb           ▰▱▱▱▱  changed together in 5 of 90 days [history]; conf 0.21
  ✎ CHANGED_BY
      ◌ alice                      ▰▰▱▱▱  37 commits [history]; conf 0.34
```

`●` confirmed · `◐` reinforced · `◌` suggested · `·` observed (derived maturity).

## What's here

- **Property-graph substrate** — `Node`, `Observation` (the primitive), `Edge`
  (the fold: derived confidence/maturity, with provenance), `Graph`.
- **Evidence model** — `structure | behavior | history | human | inference`, each
  with a type-weight and a decay half-life, evaluated against an injected clock
  (no wall-clock in the fold, so ranking is deterministic and testable).
- **Tuner** — `score = w_conf·confidence + w_recency·recency` (more terms later).
- **ColumnBuilder** — outgoing edges, grouped by relation, totally ordered.
- **Cascade + TUI** — interactive side-by-side Miller columns (`hcol walk`).
- **Workspace + on-demand providers** — neighbors are loaded lazily, only when a
  node's column is first requested. Providers: an in-memory fixture, a real
  **filesystem** (`CONTAINS`), **naming-rules** (source↔test `PAIR`), and **git**
  (`CO_CHANGED_WITH`, `CHANGED_BY` from real history).

Not yet (by design — grow small and slow): more tuner knobs (confidence floor,
evidence-mix, live retune), an event log / undo / snapshots, persistence, a
hügel-Pile provider, an agent provider. See `docs/DESIGN.md` §8.
