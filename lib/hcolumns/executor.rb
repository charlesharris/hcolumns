# frozen_string_literal: true

module HColumns
  # Execution, the opt-in half of the UI-dispatch hop (hc-4s4, layer 34c). The
  # Dispatcher queues a Request from a click; this is what puts an agent on it —
  # and the split is the safety story, not tidiness. Queuing is as safe as `hcol
  # ask` and is always available; EXECUTING is gated behind `hcol serve --dispatch`,
  # because a browser click that spawns an agent with permissions skipped is a
  # different thing to hand someone than a browser click that writes a sentence to
  # a log.
  #
  # It does NOT re-implement `hcol run`. Outstanding work is a question for the
  # graph — a Request with no LLMTask — so the same runner, the same submit path
  # and the same reconcile that the CLI uses all work unchanged here. The web is
  # just a second caller. That is also why a request queued from a browser and one
  # queued from the terminal are indistinguishable to the runner: they are the same
  # fact in the same log, and only the audit trail's `origin` tells them apart.
  #
  # WHO POLLS (Charris's call): the serve does, on the request path, exactly like
  # the Feed releases events. No supervisor thread and no detached `hcol run` — a
  # second process would mean two writers on one bridge log, which the single-writer
  # model exists to avoid. The cost is that tasks only advance while a browser is
  # open, and given the premise is a human watching the graph live, that is nearly
  # free. A task left in flight is not lost either way: reconcile/2 re-adopts it,
  # whether the next runner is a later serve or a plain `hcol run`.
  class Executor
    def initialize(runner:, worktrees: nil, audit: nil)
      @runner = runner
      @worktrees = worktrees
      @audit = audit
      @reconciled = false
    end

    attr_reader :runner, :worktrees

    # One step of the loop, driven by the serve's own request path. Submits anything
    # outstanding and advances what is already running; returns how many tasks
    # changed state, so the caller can decide whether a re-render is warranted.
    #
    # Never raises into the request path. A dispatch that explodes must fail ITS
    # task and leave the viewer working — the browser is a read surface first and an
    # execution surface second, and losing the former to a failure in the latter
    # would be the wrong trade.
    def advance(graph)
      reconcile_once(graph)
      started = @runner.submit_outstanding(graph)
      changed = @runner.poll
      Array(started).size + changed.to_i
    rescue StandardError => e
      @audit&.record("dispatch.error", origin: "ui", message: e.message)
      0
    end

    # Re-run a failed task as a fresh SECOND task on the same Request — the UI echo
    # of `hcol retry`, and USER-initiated for the same reason (Charris's call): the
    # stall detector fails fast so a human sees it and CHOOSES, and nothing here
    # auto-retries on their behalf.
    def retry_task(graph, task_key)
      started = @runner.retry(graph, task_key)
      return nil if started.empty?

      @audit&.record("dispatch.retry", origin: "ui", key: task_key, started: started)
      { ok: true, retried: task_key, tasks: started }
    rescue StandardError => e
      @audit&.record("dispatch.error", origin: "ui", key: task_key, message: e.message)
      nil
    end

    # What a finished task left behind, for the review-only merge-back: the branch
    # and what git says landed on it. Nil without worktrees (nothing was isolated,
    # so there is no branch to review) — the client uses that to decide whether to
    # offer the review affordance at all.
    def review(task_key)
      return nil unless @worktrees && task_key

      branch = @worktrees.branch_for(task_key)
      return nil unless @worktrees.branch?(branch)

      { branch: branch, head: @worktrees.head(task_key), diffstat: @worktrees.diffstat(task_key),
        commits: @worktrees.commits(task_key) }
    rescue StandardError
      nil # a repo question that fails must not break the panel it decorates
    end

    private

    # Settle anything a prior runner left stranded, once, on the first advance —
    # not in the constructor, because it needs the graph, and not per request,
    # because re-adopting on every frame would churn tmux for no gain.
    def reconcile_once(graph)
      return if @reconciled

      @reconciled = true
      @runner.reconcile(graph)
    end
  end
end
