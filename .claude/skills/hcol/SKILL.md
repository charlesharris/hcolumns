---
name: hcol
description: Read and enrich this project's live property graph (hcolumns). Use to get graph context before editing a file (who touches it — git, beads, the current session), to review what a session did per turn (nodes + token usage), to check beads/plan state, or to narrate your own work into the live view (name the session, mark phases, log milestones). The human is often WATCHING this graph live in a browser while you work.
---

# hcol — the project graph, readable and writable

hcolumns composes this repo into one property graph: filesystem, git, beads
(issues), and the **live agent session** (your own work, recorded by hooks into
`.hcolumns/live.jsonl`). The human usually has `hcol serve .` open in a browser,
watching that graph update live as you work. This skill is how you read the same
graph — and how you make what the human sees richer.

Use `./exe/hcol` when working on hcolumns itself (the working tree); plain
`hcol` (the installed gem) elsewhere. Working-tree changes are invisible to
`hcol` until `./install.sh` runs.

## Reading the graph

Everything returns the same JSON panel contract: `node`, `mode`, `modes`
(the node's available tabs — each is a valid `--mode`), and `sections` of
`items` with `label`, `target_id`, `confidence`, `reason`.

```sh
hcol json <path>                  # a file/dir's ranked relations: CONTAINS, blame,
                                  #   co-change, beads TOUCHED_BY, session TOUCHES
hcol json <path> --mode details   # + INCOMING edges (who points here), provenance,
                                  #   confidence math — best single view of a file
hcol json <path> --mode blame     # per-line commit attribution (files in git)
hcol json session                 # the live session: DRIVEN_BY, IN_PROJECT, PROPOSES
hcol json session --mode turns    # what each prompt produced, newest first,
                                  #   with token usage (in→out) per turn
hcol json obj:<id> [--mode diff]  # descend: any target_id from session-stratum JSON
                                  #   resolves in the next invocation (stable ids);
                                  #   FILE ids don't — address files by path
hcol inspect <path>               # human-readable provenance/confidence detail
```

When to reach for it:

- **Before editing an unfamiliar file**: `hcol json <file> --mode details` —
  incoming edges show whether the current session already touched it, which
  beads reference it, what co-changes with it (files that historically change
  together — a missing-edit smell).
- **"What happened / what did we do?"**: `hcol json session --mode turns`.
- **Plan context**: `hcol json . --mode beads`, then descend `HAS_BEADS` by
  `obj:` id for the issue list; a `Bead` node's `--mode bead` renders its body.
- **Session state**: `hcol json session` — the `PROPOSES` target is the working
  change-set; its `--mode diff` lists touched files + verification status.

## Writing into the live view

Hooks already record turns, edits, and test runs automatically — **never
duplicate those**. Your verbs are the ones hooks can't infer:

```sh
hcol bridge --log .hcolumns/live.jsonl "session <key> <short task title>"
hcol bridge --log .hcolumns/live.jsonl "phase exploring|editing|testing|debugging|reviewing"
hcol bridge --log .hcolumns/live.jsonl "log <milestone or decision, one line>"
```

- **`session`** — at the start of a substantive task, name it (e.g.
  `session auth-refactor Task: extract the token validator`). The browser
  header follows. Without this the session shows a stale or generic title.
- **`phase`** — on real transitions (exploring → editing → testing →
  reviewing). The UI's auto-selected tabs follow your phase; hooks only set
  `testing` (on test runs) and `reviewing` (on stop), so `exploring`/
  `debugging` are yours to signal.
- **`log`** — one line per load-bearing milestone or decision ("root cause:
  stale pid file", "switching to mutex strategy"). These appear as LogLine
  nodes under the change-set. A few per task, not per step.

Multiple commands can ride one invocation as separate args:
`hcol bridge --log .hcolumns/live.jsonl "phase editing" "log starting the lens rename"`.

## Cautions

- The bridge log **accretes across sessions** — never emit `done` into
  `.hcolumns/live.jsonl` (it deafens live tails); `done` is for one-shot logs.
- `session <key> …` re-keys the spine: reuse the existing key (see
  `hcol json session` → `identity.key`) unless you intend a new session.
- Confidence numbers: 1.0 = verifiable structure (real edits, dir entries);
  lower = decayed/probabilistic evidence (co-change, agent claims). `reason`
  strings say which.
