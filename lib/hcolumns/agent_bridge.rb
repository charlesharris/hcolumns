# frozen_string_literal: true

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
  #   edit <path>              the agent touched a file → ProposedChange TOUCHES it
  #   phase <name>             editing/testing/reviewing/… → Session :phase (drives modes)
  #   test <ok|fail> <cmd…>    a run → TestRun VERIFIED_BY the change
  #   log <text…>              an output/log line → LogLine the change EMITTED
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
      when "edit" then edit(rest)
      when "phase" then phase(rest)
      when "test" then test(rest)
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
    # hook processes don't restack it. force: a `session` command always (re)writes
    # the spine with the just-named key/title.
    def ensure_header(force: false)
      return if @header_done

      @header_done = true
      return if !force && File.exist?(@path) && !File.zero?(@path)

      session = session_node(:editing)
      agent = agent_node
      change = change_node
      emit_node(session)
      emit_node(agent)
      emit_node(change)
      emit_obs(session, agent, :DRIVEN_BY, :structure, "session actor")
      emit_obs(session, change, :PROPOSES, :agent, "the agent's working change-set")
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

    def test(rest)
      status, cmd = rest.to_s.strip.split(/\s+/, 2)
      cmd = cmd.to_s.strip
      passed = status == "ok"
      run = Node.new(type: :TestRun, identity: { scheme: "agent.test", key: "#{@session}:#{digest(cmd)}" },
                     properties: { name: cmd.empty? ? "test run" : cmd, path: cmd,
                                   output: ["#{passed ? 'PASS' : 'FAIL'} — #{cmd}"] })
      emit_node(run)
      emit_obs(change_node, run, :VERIFIED_BY, :behavior, "#{passed ? 'passed' : 'failed'}: #{cmd}")
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

    def append(line)
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
