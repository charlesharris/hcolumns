# frozen_string_literal: true

require "open3"
require "json"
require "fileutils"
require "shellwords"

module HColumns
  module Strategies
    # Drive Claude Code in a tmux pane (hc-4s4). The default strategy, and the
    # hügel lineage made explicit — hugel3 and gastown both did this, and they made
    # OPPOSITE choices. Where they disagree, we follow hugel3, because gastown's
    # own scar tissue is the argument for it.
    #
    # INPUT — bracketed paste from a file, never send-keys.
    #   tmux load-buffer -b K file ; tmux paste-buffer -b K -t T -p -d ; send-keys T Enter
    # hugel3: "keystroke injection via tmux is unreliable for multi-line input with
    # backticks, quotes, and shell metachars; bracketed paste is the only reliable
    # path for prompt CONTENT… it is the single biggest reason tmux+TUI looks
    # flaky." Gastown took the other road and paid ~1100 lines for it: 512-byte
    # chunking (the TTY line discipline truncates at 4096), a 600ms sleep to clear
    # bash readline's keyseq-timeout so ESC isn't read as a meta-prefix, a Rewind-
    # menu detector that re-sends the whole message when Escape triggers it, and a
    # per-vendor Escape-poison matrix (Escape cancels generation in Gemini/Copilot).
    # Bracketed paste makes nearly all of that unnecessary: the TUI takes the text
    # as CONTENT, so multi-line stops meaning N submits.
    #
    # COMPLETION — an event, not a heuristic. Neither prior project had this, and
    # it is the improvement. Gastown greps the pane for the literal string
    # "esc to interrupt" — undocumented, cosmetic, version-fragile, and it lies
    # often enough to need a two-consecutive-poll debounce ("during inter-tool-call
    # gaps the prompt may briefly appear while Claude Code is still working").
    # hugel3 refused to scrape and used a sentinel + result.json, which has its own
    # trap: a fixed sentinel fires the moment you PASTE a prompt containing it.
    # We use neither, because our spawned agent already carries the bridge hook:
    # launched with HCOL_BRIDGE_LOG pointed at a task-scoped log, it REPORTS
    # ITSELF, and the harness-enforced Stop hook is the completion signal. No
    # scraping, no sentinel, no echo trap.
    #
    # A task-scoped log also dodges AgentBridge#adopt_spine, which recovers the
    # session key from a log's FIRST Session node — a second agent appending to the
    # shared log would hijack the existing spine instead of opening its own.
    #
    # STALL — the completion event is what a HEALTHY task emits; a wedged one emits
    # nothing (it stops to ask an interactive question and sits there), and absence
    # of a signal is not itself a signal. So we need a liveness notion — but NOT
    # gastown's `esc to interrupt` grep, which is a content-scrape that lies. We
    # watch two TIMESTAMPS instead, either of which advancing counts as progress:
    #   1. the task log's SIZE — a hook fired (an edit, a test), definitive work; and
    #   2. tmux's own `window_activity` — bumped whenever the pane redraws, which
    #      the Claude TUI does continuously while it works (the spinner animates, the
    #      `esc to interrupt` elapsed counter ticks). Verified in tmux 3.6a: frozen
    #      during genuine silence, advancing under output. It's a timestamp tmux
    #      maintains, same category as file mtime — not a scrape of pane CONTENT.
    # The log alone is too sparse (Read/Grep and non-test Bash emit nothing to it),
    # so window_activity is the finer signal; the log is the high-value one. Quiet on
    # BOTH for STALL_TIMEOUT ⇒ failed, fast, instead of waiting out the runner's
    # whole wall-clock. This is the stall detector the readiness bug would have been
    # caught by.
    class TmuxClaudeCode
      # Fixed geometry, straight from hugel3: "any fallback to pane-scraping is
      # then deterministic."
      WIDTH = 200
      HEIGHT = 50

      # The pane must exist and Claude must be up before a paste means anything.
      BOOT_GRACE = 3.0

      # How long to wait for a trust dialog we already know is coming.
      TRUST_TIMEOUT = 20.0

      # No progress on EITHER the task log or the pane's redraw clock for this long
      # ⇒ the task is wedged (almost always waiting on input it will never get).
      # Generous on purpose: a long reasoning turn or a silent non-test build emits
      # nothing to the log, and window_activity is what covers those — but if tmux
      # ever declines the timestamp, the log-only fallback must not trip on honest
      # thinking. It's a floor, not the backstop: the runner's own wall-clock still
      # bounds the total. Failing at 120s beats failing at 600.
      STALL_TIMEOUT = 120.0

      # Charris's call, and hugel3's: a permission prompt in a detached pane is
      # invisible — the session just wedges with no error, and the runner learns
      # nothing until its wall-clock timeout. hugel3 shipped the same default for
      # the same reason ("silent permission prompts wedge interactive Claude
      # sessions with no visible error").
      #
      # This is a real trade-off, taken deliberately: the spawned agent can act
      # unattended on the repo it is pointed at. Point it at a worktree when the task
      # is not trusted — the seam allows it (`command:` and `root:` are injectable).
      # It does NOT cover the workspace-trust dialog; see TRUST_DIALOG below.
      DEFAULT_COMMAND = "claude --dangerously-skip-permissions"

      # The workspace-trust dialog, which --dangerously-skip-permissions does NOT
      # cover — verified live in an untrusted dir, not taken on faith (hugel3 found
      # the same for --permission-mode bypassPermissions; it holds for this flag
      # too). It is a numbered menu with option 1 pre-selected:
      #
      #     ❯ 1. Yes, I trust this folder
      #       2. No, exit
      #     Enter to confirm · Esc to cancel
      #
      # So the bypass is ONE Enter. Not `yes(1)`: that streams "y\n" at stdin, but
      # a TUI reads raw keys from the tty and this menu wants Enter — and `yes`
      # never stops, so after the dialog cleared it would type into the prompt box
      # forever, submitting garbage.
      TRUST_DIALOG = /Yes, I trust this folder/
      TRUST_CONFIG = "~/.claude.json"

      class << self
        # Has Claude Code already been trusted here? A FACT, read from its own
        # config — not a guess and not a screen-scrape. This is what makes the
        # Enter below safe: we press it only when we already know a dialog is
        # coming, so we are confirming an expectation rather than inferring state
        # from pane bytes (the mistake that makes gastown's idle detection lie).
        def trusted?(root, config: TRUST_CONFIG)
          path = File.expand_path(config)
          return true unless File.file?(path)

          JSON.parse(File.read(path)).dig("projects", File.expand_path(root), "hasTrustDialogAccepted") == true
        rescue JSON::ParserError, SystemCallError
          false # can't tell → assume the dialog may appear; a wasted wait beats a wedge
        end
      end

      # `worktrees:` is the seam the comment above always promised. Given a
      # Worktrees, each task runs in its OWN checkout on branch hcol/<key> instead
      # of in @root — the agent commits there and the human's working tree is never
      # touched. Nil keeps the historical behaviour (run in place), which is what
      # the CLI does without --worktree.
      #
      # `audit:` is nil-tolerant for the same reason the runner's other collaborators
      # are: a test double should not have to grow a disk file to exercise spawning.
      # The CLI always passes one.
      def initialize(root:, command: DEFAULT_COMMAND, tasks_dir: nil, hcol_bin: nil,
                     worktrees: nil, audit: nil, origin: "cli", clock: -> { Time.now })
        @root = File.expand_path(root)
        @command = command
        # Tasks stay under the MAIN repo, never the worktree: the logs and the durable
        # pane output are the record of the task, and they have to outlive a worktree
        # that gets removed. It is also what lets adopt/2 find them from the key alone
        # without first resolving which tree the task happened to run in.
        @tasks_dir = tasks_dir || File.join(@root, ".hcolumns", "tasks")
        @hcol_bin = hcol_bin || "hcol"
        @worktrees = worktrees
        @audit = audit
        @origin = origin
        @clock = clock
      end

      attr_reader :worktrees

      # The TUI's input prompt. Matched as the bare glyph on purpose: gastown
      # matched "❯ " with a regular space and broke, because Claude Code emits a
      # NBSP after it (their issue #1387). Nothing downstream needs the space.
      #
      # This is readiness detection, not completion detection — the one use of
      # pane-scraping hugel3 kept too ("reads capture-pane for boot-readiness UI
      # detection"). Being wrong here costs a retry on the next poll; being wrong
      # about completion would cost a truncated answer.
      #
      # But ❯ ALONE IS NOT READY, and this cost a real run to learn: the trust
      # dialog draws its selected option as "❯ 1. Yes, I trust this folder". So
      # the instant accept_trust pressed Enter, the still-rendered dialog matched,
      # the prompt was pasted onto a dying screen, delivery was marked done, and
      # the task waited out its whole timeout for an answer to a question nothing
      # had been asked. Exactly gastown's bug — a marker that appears in a state
      # you are not in yet. Readiness is the prompt AND no dialog over it.
      READY_PROMPT = /❯/

      def ready?(handle)
        out, = tmux("capture-pane", "-p", "-J", "-t", handle.pane)
        out.match?(READY_PROMPT) && !out.match?(TRUST_DIALOG)
      end

      Handle = Struct.new(:key, :session, :log, :prompt_file, :pane_out, :started_at, :pane, :delivered,
                          :last_progress_at, :last_size, :last_activity, :root, :branch, keyword_init: true)

      def start(task)
        FileUtils.mkdir_p(@tasks_dir)
        handle = Handle.new(key: task.key, session: session_name(task.key), log: File.join(@tasks_dir, "#{task.key}.jsonl"),
                            prompt_file: File.join(@tasks_dir, "#{task.key}.prompt"),
                            pane_out: File.join(@tasks_dir, "#{task.key}.pane"),
                            started_at: @clock.call, delivered: false, last_size: 0,
                            root: workspace_for(task.key), branch: @worktrees&.branch_for(task.key))
        File.write(handle.prompt_file, "#{task.prompt}\n")

        # Recorded BEFORE the pane exists, so an agent that wedges on its first
        # breath still leaves a record of having been started — the gap an
        # after-the-fact audit would have.
        audit(:spawn, task.key, request_id: task.request_id, root: handle.root, branch: handle.branch,
                               command: @command, session: handle.session, prompt: task.prompt.to_s)

        kill(handle.session) # idempotent: hugel3 kills first rather than check-then-create
        spawn(handle)
        handle.pane = resolve_pane(handle.session)
        start_pipe(handle) # durable output channel, attached the moment the pane exists
        # A FRESH worktree is a folder Claude Code has never seen, so the trust
        # dialog is expected here rather than incidental — the check is per-root,
        # not per-repo, and accept_trust is what clears it.
        accept_trust(handle) unless self.class.trusted?(handle.root)
        handle
      end

      # Where this task's agent actually runs. With worktrees configured this
      # CREATES the tree (idempotently) — the one place the isolation is materialised,
      # so nothing else in the strategy has to know whether it is isolated or not.
      def workspace_for(key)
        @worktrees ? @worktrees.ensure(key) : @root
      end

      # Attach a DURABLE output channel the moment the pane exists (hc-4s4, pipe-pane).
      # capture-pane only renders the VISIBLE grid and cannot read a pane that has since
      # died; pipe-pane streams every byte the pane emits to a file that outlives it —
      # so the answer is complete (not just the last screen) and recoverable even after
      # the pane closes. The path derives from the key like everything else, so a later
      # runner that ADOPTS this task reads the same file WITHOUT re-attaching (a second
      # `-o` would toggle the pipe shut). Best-effort: a pipe that won't attach must not
      # fail the task — answer() falls back to the live capture.
      def start_pipe(handle)
        tmux("pipe-pane", "-o", "-t", handle.pane, "cat >> #{Shellwords.escape(handle.pane_out)}")
      rescue StandardError
        nil
      end

      # Clear the first-run trust dialog. Deliberately NOT done by writing
      # `hasTrustDialogAccepted` into ~/.claude.json: that file is 200KB+ of global
      # state across every project, Claude Code writes it concurrently, and
      # corrupting it would break every repo at once — gastown shipped an atomic
      # settings.json write after exactly that class of bug. One keystroke into our
      # own pane touches nothing outside this task.
      #
      # Bounded: if the dialog never shows we return and let the task proceed, so a
      # renamed string costs a few seconds, not a hang.
      def accept_trust(handle, timeout: TRUST_TIMEOUT, interval: 0.25, sleeper: ->(s) { sleep(s) })
        waited = 0.0
        until pane_shows?(handle, TRUST_DIALOG)
          return false if waited >= timeout

          sleeper.call(interval)
          waited += interval
        end
        tmux("send-keys", "-t", handle.pane, "Enter") # option 1 is pre-selected
        true
      end

      # Two jobs, in order: get the prompt in, then notice it's answered.
      #
      # Delivery lives HERE rather than in start() so a boot doesn't block the
      # runner — Claude takes ~10s to come up, and several tasks should be able to
      # boot at once. The prompt cannot be pasted until the TUI exists to receive
      # it, so the handle carries whether that has happened yet.
      #
      # Done when the spawned agent's own hook says so. `phase reviewing` is what
      # the Stop hook emits — harness-enforced, so it cannot be fooled by a
      # cosmetic string or by the prompt echoing itself. Verified against a real
      # agent: the hook fired ~4s after it answered.
      # Wrapped so that EVERY terminal outcome funnels through one audit point.
      # Auditing at each `return` would be four call sites and a fifth one waiting to
      # be forgotten the next time a failure mode is added — and a missing outcome
      # record is indistinguishable from a task that never ended.
      def poll(handle)
        result = poll_result(handle)
        audit_outcome(handle, result) unless result == :running
        result
      end

      def poll_result(handle)
        # Finished-on-disk wins over a vanished pane. A task this runner ADOPTED after
        # a restart may have completed and had its pane close before we looked — the
        # answer is still on disk, so read it back rather than mourn it as a failure.
        # Checking this first is what lets `hcol run` survive its own shell.
        if handle.delivered && File.file?(handle.log) && finished?(handle.log)
          return { status: :done, response: answer(handle) }
        end

        return { status: :failed, response: "tmux session #{handle.session} vanished" } unless alive?(handle.session)

        unless handle.delivered
          return :running unless ready?(handle)

          deliver(handle)
          handle.delivered = true
          handle.last_progress_at = @clock.call # start the stall clock at delivery, not boot
          return :running
        end

        if stalled?(handle, now: @clock.call, log_size: log_size(handle), activity_at: pane_activity_at(handle))
          return { status: :failed, response: stall_message }
        end

        :running
      end

      # Rebuild the handle for a task a PREVIOUS runner started, so this one can poll
      # it to a conclusion (hc-4s4). Everything the handle needs is deterministic from
      # the key — the session name and the task-log path both derive from it, which
      # was the whole point of keying them off it. Marked delivered: an in-flight task
      # was pasted long ago, and re-delivering would inject the prompt a second time.
      def adopt(key)
        session = session_name(key)
        handle = Handle.new(key: key, session: session, log: File.join(@tasks_dir, "#{key}.jsonl"),
                            prompt_file: File.join(@tasks_dir, "#{key}.prompt"),
                            pane_out: File.join(@tasks_dir, "#{key}.pane"), # same durable file the original run pipes to
                            started_at: @clock.call, delivered: true, last_size: 0,
                            last_progress_at: @clock.call,
                            # Derived, never re-created: adopting must not resurrect a
                            # worktree a cleanup already removed. The path is where the
                            # tree WAS, which is what the audit record wants either way.
                            root: @worktrees ? @worktrees.path_for(key) : @root,
                            branch: @worktrees&.branch_for(key))
        handle.pane = resolve_pane(session) if alive?(session)
        audit(:adopt, key, root: handle.root, branch: handle.branch, session: session)
        handle
      end

      # Bookkeep progress and report whether the task has gone quiet past the floor.
      # Pure given the two readings, so the whole stall policy is testable without a
      # pane: pass a fake clock and synthetic log_size/activity_at. Either the log
      # growing (real work) or window_activity advancing (the pane redrawing) resets
      # the clock; quiet on both for `timeout` ⇒ stalled.
      def stalled?(handle, now:, log_size:, activity_at:, timeout: STALL_TIMEOUT)
        grew   = log_size > handle.last_size.to_i
        redrew = activity_at && handle.last_activity && activity_at > handle.last_activity
        handle.last_size = log_size if grew
        handle.last_activity = activity_at if activity_at
        handle.last_progress_at = now if grew || redrew || handle.last_progress_at.nil?
        (now - handle.last_progress_at) >= timeout
      end

      # Best-effort teardown, and a real one. Orphan panes are a documented plague in
      # both prior projects (gastown ships a reconciler AND a process-tree reaper
      # because the agent ignores SIGHUP; hugel3 reaps in terminate/2 "so an abnormal
      # exit doesn't leak orphan panes"). `kill-session` SIGHUPs the pane's process
      # group and removes the pane — but the agent is exactly the process that
      # ignores SIGHUP, so its node/child processes survive detached. So we capture
      # the pane's pid FIRST, kill the session, then SIGKILL anything left in that
      # tree. Every step is best-effort: teardown must never raise into the runner.
      def stop(handle)
        return unless handle

        pid = pane_pid(handle) # before kill-session, while the pane still exists to ask
        kill(handle.session)
        reap_tree(pid) if pid
      end

      # Reap the panes of tasks the graph already calls terminal (hc-4s4). A done or
      # failed task whose hcol-<key> session is still alive is a leak — the prior
      # runner died between recording the outcome and tearing the pane down.
      # Conservative by construction: only sessions for PROVABLY finished tasks are
      # touched, never one a concurrent live runner might still own (that runner's own
      # stall detector reaps its wedged case). A truly orphaned pane with no graph
      # record is left alone rather than risk killing a session mid-flight.
      def reap_orphans(terminal_keys)
        terminal_keys.each do |key|
          session = session_name(key)
          stop(Handle.new(session: session)) if alive?(session)
        end
      end

      # SIGKILL a pid and every descendant, leaves first so a parent can't reparent a
      # child onto init before we reach it. `children_of` is injected so the tree
      # walk is testable without real processes.
      def reap_tree(pid, children_of: method(:child_pids))
        descendants(pid, children_of).reverse_each do |p|
          Process.kill("KILL", p)
        rescue Errno::ESRCH, Errno::EPERM
          nil # already gone, or not ours — either way, nothing to reap
        end
      end

      # A pid and all its descendants, parents-before-children (DFS). Pure given
      # `children_of`; the caller reverses it to kill leaves first.
      def descendants(pid, children_of)
        seen = []
        stack = [pid]
        until stack.empty?
          current = stack.pop
          next if seen.include?(current)

          seen << current
          stack.concat(children_of.call(current))
        end
        seen
      end

      # The prompt delivery hugel3 arrived at, kept together so it reads as one
      # protocol. `-p` is bracketed paste; `-d` deletes the buffer after; Enter is
      # a SEPARATE keystroke, because it is the submit, not part of the content.
      def deliver(handle)
        buffer = "hcol-#{handle.session}"
        tmux("load-buffer", "-b", buffer, handle.prompt_file)
        tmux("paste-buffer", "-b", buffer, "-t", handle.pane, "-p", "-d")
        tmux("send-keys", "-t", handle.pane, "Enter")
      end

      private

      # One line per auditable moment. `origin` rides on every record because it is
      # the question the log exists to answer: a task that ran because someone
      # clicked in a browser should be distinguishable from one you started
      # yourself, without inferring it from timestamps.
      def audit(event, key, **fields)
        @audit&.record("dispatch.#{event}", key: key, origin: @origin, **fields)
      end

      # What the agent DID, asked of git rather than of the agent. The response text
      # is the agent's own account and is recorded as such; the sha and diffstat are
      # the part that cannot be talked around. Best-effort — a repo question that
      # fails must not turn a finished task into a failed one.
      def audit_outcome(handle, result)
        facts = { status: result[:status].to_s, response: result[:response].to_s }
        if @worktrees && handle.key
          begin
            facts[:head] = @worktrees.head(handle.key)
            facts[:diffstat] = @worktrees.diffstat(handle.key)
            facts[:commits] = @worktrees.commits(handle.key).map { |c| c[:sha] }
          rescue StandardError => e
            facts[:repo_error] = e.message
          end
        end
        audit(:outcome, handle.key, branch: handle.branch, **facts)
      end

      def session_name(key)
        # No dots or colons: tmux reads those as target syntax (gastown validates
        # against exactly this).
        "hcol-#{key}".gsub(/[^a-zA-Z0-9_-]/, "-")
      end

      # -e passes the environment in, which is the whole trick: the spawned agent's
      # bridge hook writes to THIS task's log, so its work comes back structured
      # instead of scraped.
      def spawn(handle)
        tmux("new-session", "-d", "-s", handle.session, "-x", WIDTH.to_s, "-y", HEIGHT.to_s,
             "-c", handle.root || @root, "-e", "HCOL_BRIDGE_LOG=#{handle.log}", "-e", "HCOL_BIN=#{@hcol_bin}",
             @command)
      end

      # Address the PANE explicitly, never the bare session name: gastown found
      # that `send-keys -t <session>` goes to whatever pane the human last clicked.
      def resolve_pane(session)
        out, = tmux("list-panes", "-t", session, "-F", "\#{session_name}:\#{window_index}.\#{pane_index}")
        out.to_s.lines.first&.strip || session
      end

      def alive?(session)
        _out, _err, status = Open3.capture3("tmux", "has-session", "-t", session)
        status.success?
      end

      def stall_message(timeout = STALL_TIMEOUT)
        "stalled: no output and no logged work for #{timeout.to_i}s (pane idle — likely waiting on input)"
      end

      def log_size(handle)
        File.file?(handle.log) ? File.size(handle.log) : 0
      end

      # tmux's last-redraw timestamp for the pane's window (epoch seconds), or nil if
      # the build/pane won't give one — in which case the log is the only heartbeat.
      # A single-window session, so window_activity IS this pane's activity.
      def pane_activity_at(handle)
        out, = tmux("display-message", "-p", "-t", handle.pane, "\#{window_activity}")
        text = out.to_s.strip
        text.empty? ? nil : Integer(text)
      rescue StandardError
        nil
      end

      # The pane's foreground pid — the root of the tree stop() reaps.
      def pane_pid(handle)
        out, = tmux("list-panes", "-t", handle.session, "-F", "\#{pane_pid}")
        text = out.to_s.lines.first&.strip
        text && !text.empty? ? Integer(text) : nil
      rescue StandardError
        nil
      end

      def child_pids(pid)
        out, _err, status = Open3.capture3("pgrep", "-P", pid.to_s)
        status.success? ? out.split.map { |s| Integer(s) } : []
      rescue StandardError
        []
      end

      def kill(session)
        Open3.capture3("tmux", "kill-session", "-t", session)
      end

      # The Stop hook's `phase reviewing`, or an explicit eof — a one-shot task log
      # is exactly the stream where `done` is legitimate.
      def finished?(log)
        File.foreach(log).any? do |line|
          parsed = begin
            Persistence.parse_line(line)
          rescue StandardError
            nil
          end
          parsed == :eof ||
            (parsed.is_a?(Hash) && parsed[:kind] == :node &&
             parsed[:payload].respond_to?(:properties) &&
             parsed[:payload].properties[:phase] == :reviewing)
        end
      end

      # The prose answer. Prefers the DURABLE pipe-pane capture, which holds the whole
      # session and reads back even after the pane has closed (an adopted task whose
      # original runner died); falls back to the live capture-pane tail if no pipe file
      # exists, and to a task-log pointer if there is nothing to show at all. The real
      # STRUCTURE always comes through the task log regardless — this is just the prose.
      def answer(handle)
        captured = pane_output(handle)
        return captured unless captured.empty?
        return transcript_tail(handle) if alive?(handle.session)

        "completed — no captured output; work is in #{handle.log}"
      end

      # Read and clean the durable capture. Works with a dead pane; empty string when
      # there is nothing (no pipe attached, or it never wrote).
      def pane_output(handle, lines: 60)
        path = handle.pane_out
        return "" unless path && File.file?(path) && File.size(path).positive?

        clean_pane_capture(File.binread(path), lines: lines)
      rescue SystemCallError
        ""
      end

      # Turn a raw pipe-pane capture — ANSI escapes, cursor repaints, carriage-return
      # overwrites — into legible prose. Version-AGNOSTIC on purpose: no per-vendor
      # chrome matrix (the gastown trap). It strips control sequences, resolves each \r
      # to the text that won, drops blank lines, and collapses the CONSECUTIVE duplicate
      # lines a TUI's repaint leaves behind, then keeps the tail. Not a faithful screen
      # reconstruction — a durable, readable record that outlives scrollback and the pane.
      CSI = /\e\[[0-9;?]*[ -\/]*[@-~]/.freeze
      OSC = /\e\][^\a\e]*(?:\a|\e\\)/.freeze

      def clean_pane_capture(raw, lines: 60)
        text = raw.to_s.dup.force_encoding("UTF-8").scrub
        text = text.gsub(CSI, "").gsub(OSC, "").gsub(/\e[()][AB0]/, "").gsub(/\e[=>]/, "")
        out = []
        text.split("\n").each do |physical|
          resolved = (physical.include?("\r") ? physical.split("\r").last : physical).to_s.rstrip
          next if resolved.empty? || out.last == resolved # drop blanks and consecutive repaint dupes

          out << resolved
        end
        out.last(lines).join("\n")
      end

      # The human-readable answer. The STRUCTURE comes back through the task log
      # (turns, edits, TestRuns); this is only the prose, and it is explicitly the
      # lossy channel — capture-pane renders the visible pane, so anything that
      # scrolled past is gone. -J joins wrapped lines.
      def transcript_tail(handle, lines: 40)
        out, = tmux("capture-pane", "-p", "-J", "-t", handle.pane, "-S", "-#{lines}")
        out.to_s.lines.map(&:rstrip).reject(&:empty?).last(lines).join("\n")
      end

      def pane_shows?(handle, pattern)
        out, = tmux("capture-pane", "-p", "-J", "-t", handle.pane)
        out.to_s.match?(pattern)
      end

      def tmux(*args)
        out, err, status = Open3.capture3("tmux", *args)
        raise "tmux #{args.first} failed: #{err.strip}" unless status.success?

        [out, err]
      end
    end
  end
end
