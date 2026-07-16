# frozen_string_literal: true

require "open3"
require "json"
require "fileutils"

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
    class TmuxClaudeCode
      # Fixed geometry, straight from hugel3: "any fallback to pane-scraping is
      # then deterministic."
      WIDTH = 200
      HEIGHT = 50

      # The pane must exist and Claude must be up before a paste means anything.
      BOOT_GRACE = 3.0

      # How long to wait for a trust dialog we already know is coming.
      TRUST_TIMEOUT = 20.0

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

      def initialize(root:, command: DEFAULT_COMMAND, tasks_dir: nil, hcol_bin: nil, clock: -> { Time.now })
        @root = File.expand_path(root)
        @command = command
        @tasks_dir = tasks_dir || File.join(@root, ".hcolumns", "tasks")
        @hcol_bin = hcol_bin || "hcol"
        @clock = clock
      end

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

      Handle = Struct.new(:session, :log, :prompt_file, :started_at, :pane, :delivered, keyword_init: true)

      def start(task)
        FileUtils.mkdir_p(@tasks_dir)
        handle = Handle.new(session: session_name(task.key), log: File.join(@tasks_dir, "#{task.key}.jsonl"),
                            prompt_file: File.join(@tasks_dir, "#{task.key}.prompt"),
                            started_at: @clock.call, delivered: false)
        File.write(handle.prompt_file, "#{task.prompt}\n")

        kill(handle.session) # idempotent: hugel3 kills first rather than check-then-create
        spawn(handle)
        handle.pane = resolve_pane(handle.session)
        accept_trust(handle) unless self.class.trusted?(@root)
        handle
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
      def poll(handle)
        return { status: :failed, response: "tmux session #{handle.session} vanished" } unless alive?(handle.session)

        unless handle.delivered
          return :running unless ready?(handle)

          deliver(handle)
          handle.delivered = true
          return :running
        end

        return :running unless File.file?(handle.log) && finished?(handle.log)

        { status: :done, response: transcript_tail(handle) }
      end

      # Best-effort teardown. Orphan panes are a documented plague in both prior
      # projects (gastown ships a reconciler AND a process-tree reaper because the
      # agent ignores SIGHUP; hugel3 reaps in terminate/2 "so an abnormal exit
      # doesn't leak orphan panes").
      def stop(handle)
        kill(handle.session) if handle
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
             "-c", @root, "-e", "HCOL_BRIDGE_LOG=#{handle.log}", "-e", "HCOL_BIN=#{@hcol_bin}",
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
