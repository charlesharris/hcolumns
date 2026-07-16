# frozen_string_literal: true

require "fileutils"

module HColumns
  # The real agent bridge (hc-gzj): a live coding agent's actions become
  # Persistence-format events on an append-only JSONL log — the producer the
  # `hcol produce` demo script stood in for. hcolumns stays *agent-agnostic*: it
  # speaks a small neutral vocabulary, and a thin external hook (a Claude Code
  # PostToolUse hook, a git hook, any wrapper) translates its world into these
  # lines. The transport underneath — append-only log + TailReader + SSE — is the
  # one already proven by layers 16–18, so `hcol walk/serve <log> --live` shows
  # the session grow with no further work.
  #
  # The vocabulary (one command per line, on stdin or argv):
  #
  #   session <key> <title…>   name the session (its Session node is the log root)
  #   turn <label…>            a turn boundary — everything until the next marker
  #                            belongs to this turn (ordinals derived at fold time)
  #   edit <path>              the agent touched a file → ProposedChange TOUCHES it
  #   phase <name>             editing/testing/reviewing/… → Session :phase (drives modes)
  #   test <start|ok|fail> <cmd…>  a run's lifecycle → one TestRun node (digest-keyed
  #                            by cmd) re-emitted per state, latest fold wins — the
  #                            :phase pattern, so a live walk shows ◐ flip to ✓/✗
  #   log <text…>              an output/log line → LogLine the change EMITTED
  #   request <key> <prompt…>  an INTENT, not an observation: someone wants a fix.
  #                            An external runner picks it up; the log only records
  #                            that it was asked for (hc-bnh).
  #   transcript <path>        where the session's raw context lives → a Transcript
  #                            node the context stratum expands lazily (hc-33x).
  #                            A pointer, never the corpus: the ~700k tokens stay
  #                            on disk until someone descends.
  #   done                     the eof marker (the live badge flips to "complete")
  #
  # A hook fires the bridge once per event, so it is a *fresh process every time*
  # and holds no memory across calls. That's fine because the session's spine —
  # the Session, Agent, and ProposedChange nodes — is **deterministic from the
  # session key** (same identity ⇒ same id), so any process can emit an edge that
  # references them correctly. The one-time header (those three nodes + the
  # DRIVEN_BY / PROPOSES edges) is written only while the log is still empty.
  #
  # Node/edge shapes mirror Providers::AgentSession exactly, so a live-bridged
  # session is indistinguishable from the fixture — the touched files are *real*
  # fs.path nodes, so they unify with the filesystem/git/ruby/beads graph (a walk
  # descends change → file → blame → commit, and the beads reverse walk lights up).
  class AgentBridge
    def initialize(path:, session: "live", title: nil, clock: -> { Time.now })
      @path = path
      @session = session
      @title = title
      @clock = clock
      @header_done = false
    end

    # Dispatch one neutral-vocabulary line. Unknown verbs warn and are skipped, so
    # a noisy hook never crashes the agent it's attached to.
    def apply(command)
      verb, rest = command.to_s.strip.split(/\s+/, 2)
      return if verb.nil? || verb.empty?

      ensure_header unless verb == "session"
      case verb
      when "session" then start(rest)
      when "turn" then turn(rest)
      when "edit" then edit(rest)
      when "phase" then phase(rest)
      when "transcript" then transcript(rest)
      when "request" then request(rest)
      when "test" then test(rest)
      when "usage" then usage(rest)
      when "log" then log_line(rest)
      when "done", "finish" then finish
      else warn "bridge: ignoring unknown command #{verb.inspect}"
      end
    end

    private

    def now = @clock.call

    # --- the deterministic spine (same identity in every process) ---

    def session_node(phase)
      name = @title && !@title.empty? ? "Task: #{@title}" : "session #{@session}"
      Node.new(type: :Session, identity: { scheme: "agent.session", key: @session },
               properties: { name: name, phase: phase })
    end

    def agent_node
      Node.new(type: :Agent, identity: { scheme: "agent", key: "claude" }, properties: { name: "claude" })
    end

    def change_node
      Node.new(type: :ProposedChange, identity: { scheme: "agent.change", key: "#{@session}:c1" },
               properties: { name: "working change-set", hunks: {} })
    end

    # --- verbs ---

    def start(rest)
      key, title = rest.to_s.strip.split(/\s+/, 2)
      @session = key unless key.nil? || key.empty?
      @title = title
      ensure_header(force: true)
    end

    # The header is written once — only when the log is still empty, so repeated
    # hook processes don't restack it; a later process *adopts* the spine already
    # on disk instead. force: a `session` command always (re)writes the spine with
    # the just-named key/title.
    def ensure_header(force: false)
      return if @header_done

      @header_done = true
      return adopt_spine if !force && File.exist?(@path) && !File.zero?(@path)

      session = session_node(:editing)
      agent = agent_node
      change = change_node
      emit_node(session)
      emit_node(agent)
      emit_node(change)
      emit_obs(session, agent, :DRIVEN_BY, :structure, "session actor")
      emit_obs(session, change, :PROPOSES, :agent, "the agent's working change-set")
    end

    # A fresh process can't know which key the log was opened under — assuming the
    # default would hang every edge off a spine that was never emitted (found live,
    # second dogfood session: a `session dogfood` header, then weeks of hook
    # processes writing edges from the ghost "live:c1"). The log knows: recover
    # key/title from its first Session node, so "same identity ⇒ same id" holds
    # across processes no matter what the session was named.
    def adopt_spine
      File.foreach(@path) do |line|
        parsed = Persistence.parse_line(line) rescue nil
        next unless parsed.is_a?(Hash) && parsed[:kind] == :node

        node = parsed[:payload]
        next unless node.identity[:scheme] == "agent.session"

        @session = node.identity[:key]
        name = node.properties[:name].to_s
        @title = name.delete_prefix("Task: ") if name.start_with?("Task: ")
        break
      end
    end

    # A turn boundary. Deliberately just a marker: the fold assigns ordinals from
    # log order (Graph#apply_turn), so this stateless process never has to know
    # which turn number it's on — the log knows.
    def turn(rest)
      label = rest.to_s.strip
      append(Persistence.line_for(kind: :turn, payload: { label: label.empty? ? nil : label, at: now }))
    end

    def edit(rest)
      raw = rest.to_s.strip
      return if raw.empty?

      file = Providers::Filesystem.node_for(raw)
      emit_node(file)
      # The edit is a verifiable action (the file really changed) → :structure 1.0,
      # like AgentSession's TOUCHES; the file is a real fs.path, so it unifies.
      emit_obs(change_node, file, :TOUCHES, :structure, "edited #{File.basename(raw)}")
    end

    def phase(rest)
      name = rest.to_s.strip
      return if name.empty?

      # Re-emit the Session node with the new phase — latest fold wins, exactly the
      # event AgentSession uses to drive the live mode resolver.
      emit_node(session_node(name.to_sym))
    end

    # `transcript <path>` — the POINTER to the session's raw context (hc-33x).
    # Only the hook knows this path, and the graph can't re-derive it; the
    # ~700k tokens it addresses stay on disk, read lazily by Providers::Transcript
    # when someone actually descends. So the log records an address, not a corpus.
    #
    # A node of its own rather than a Session property: a stateless `phase` call
    # from a later hook process re-emits the Session and would REPLACE properties
    # it can't know (apply_node is last-word-wins on the whole node), silently
    # dropping the path. An edge accretes instead — and the transcript is a thing
    # in its own right, with blocks hanging off it.
    # `request <key> <prompt…>` — the log's first INTENT (hc-bnh). Everything else
    # in this vocabulary records what happened; this records what someone WANTS to
    # happen, so that an external runner can pick it up and put an agent on it.
    #
    # The event is still an observation: it records that a request WAS MADE, at a
    # time, by someone. It does not *do* anything. Dispatch belongs to the
    # consumer, which tracks its own cursor — exactly as TailReader and the SSE
    # streams already do. That separation is load-bearing: the log is replayed on
    # every `hcol walk f.jsonl`, and a request that fired on replay would re-run a
    # fix weeks later, from a snapshot, with no one watching.
    #
    # hcolumns stays agent-agnostic here too. This emits a NEUTRAL prompt; the
    # thin runner that turns it into `claude -p` is external, the mirror of the
    # hook on the way in. And the loop closes: that agent's own bridge hook writes
    # its work back into this same log as a ProposedChange.
    def request(rest)
      key, prompt = rest.to_s.strip.split(/\s+/, 2)
      return if key.nil? || key.empty? || prompt.to_s.strip.empty?

      node = Node.new(type: :FixRequest, identity: { scheme: "agent.request", key: "#{@session}:#{key}" },
                      properties: { name: "fix requested: #{prompt.to_s.strip[0, 50]}", prompt: prompt.to_s.strip,
                                    subject: key, state: :open, requested_by: ENV["USER"] || "user" })
      emit_node(node)
      # :agent evidence, not :structure — a request is a stated intent, not a
      # verified fact about the world.
      emit_obs(session_node(:editing), node, :REQUESTED, :agent, "fix requested for #{key}")
    end

    def transcript(rest)
      path = rest.to_s.strip
      return if path.empty?

      full = File.expand_path(path)
      node = Providers::Transcript.node_for(full)
      emit_node(node)
      # session_node's phase argument is irrelevant here: an id comes from identity
      # alone, and we only want the spine's id to hang the edge from. Deliberately
      # NOT re-emitting the Session node — that would clobber the live phase.
      emit_obs(session_node(:editing), node, :HAS_TRANSCRIPT, :structure, "the session's raw context")
    end

    # A test run's lifecycle as node states (the juggler takeaway, survey #2:
    # their tool-action state machine, done the event-sourced way). `start` emits
    # the TestRun in :running; `ok`/`fail` RE-EMIT the same node (digest-keyed by
    # cmd, same identity ⇒ same id) in its final state — latest fold wins, exactly
    # how :phase drives the Session. In-flight work is visible in the columns and
    # flips in place when the result lands. `ok`/`fail` still work standalone
    # (today's after-the-fact usage) — the bridge is stateless, so no pairing.
    TEST_STATES = {
      "start" => { state: :running, glyph: "◐", word: "started" },
      "ok" => { state: :passed, glyph: "✓", word: "passed" },
      "fail" => { state: :failed, glyph: "✗", word: "failed" }
    }.freeze

    def test(rest)
      status, cmd = rest.to_s.strip.split(/\s+/, 2)
      cmd = cmd.to_s.strip
      spec = TEST_STATES.fetch(status, TEST_STATES["fail"])
      run = test_node(cmd, spec)
      emit_node(run)
      emit_obs(change_node, run, :VERIFIED_BY, :behavior, "#{spec[:word]}: #{cmd}")
    end

    def test_node(cmd, spec)
      name = cmd.empty? ? "test run" : cmd
      Node.new(type: :TestRun, identity: { scheme: "agent.test", key: "#{@session}:#{digest(cmd)}" },
               properties: { name: "#{spec[:glyph]} #{name}", state: spec[:state], path: cmd,
                             output: ["#{spec[:word].upcase} — #{cmd}"] })
    end

    # The open turn's token totals — `usage in=42000 out=3200 cache_read=… cache_create=…`.
    # TOTALS, not deltas: the fold is last-word-wins (Graph#apply_usage), so this
    # stateless process can re-report the running numbers at any frequency —
    # once at turn end, or per tool call for live ticking — without ever
    # double-counting. Unknown keys ride along; the display picks what it shows.
    def usage(rest)
      tokens = rest.to_s.scan(/([a-z_]+)=(\d+)/).to_h { |key, value| [key.to_sym, value.to_i] }
      return if tokens.empty?

      append(Persistence.line_for(kind: :usage, payload: { tokens: tokens, at: now }))
    end

    def log_line(rest)
      text = rest.to_s.strip
      return if text.empty?

      line = Node.new(type: :LogLine, identity: { scheme: "agent.log", key: "#{@session}:#{digest(text)}" },
                      properties: { name: text, path: text, output: [text] })
      emit_node(line)
      emit_obs(change_node, line, :EMITTED, :agent, "log line")
    end

    def finish
      append(Persistence.eof_line)
    end

    # --- emit (Persistence lines, flushed per line for a tailing consumer) ---

    def emit_node(node)
      append(Persistence.line_for(kind: :node, payload: node))
    end

    def emit_obs(subject, target, type, kind, summary)
      obs = Observation.new(provider: :agent, subject_id: subject.id, target_id: target.id,
                            edge_type: type, weight: 1.0, evidence_kind: kind,
                            observed_at: now, evidence_summary: summary)
      append(Persistence.line_for(kind: :observe, payload: obs))
    end

    # The log's directory is made on demand: a fresh repo has no .hcolumns/, and
    # the hook that feeds us swallows errors (a bridge hiccup must never fail the
    # tool call it observes) — so without this, `hcol init` elsewhere would install
    # cleanly and then record nothing, silently. Same posture as FlagStore.
    def append(line)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, "a") do |io|
        io.puts(line)
        io.flush
      end
    end

    # A stable, dependency-free short key (djb2) so a repeated test/log command maps
    # to the same node (its status/output just updates) instead of piling up nodes.
    def digest(text)
      text.to_s.each_char.reduce(5381) { |h, ch| ((h * 33) ^ ch.ord) & 0xffffffff }.to_s(16)
    end
  end
end
