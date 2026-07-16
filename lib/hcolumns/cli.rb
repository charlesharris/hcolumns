# frozen_string_literal: true

module HColumns
  # A thin client over a Workspace. A real filesystem path is indexed lazily via
  # the filesystem + naming providers; anything else selects into the in-memory
  # demo graph.
  class CLI
    def self.run(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      cmd = @argv.shift || "explore"
      @opts = parse_opts!
      case cmd
      when "explore" then explore(@argv.first)
      when "walk" then walk(@argv.first)
      when "inspect" then inspect_node(@argv.first)
      when "json" then emit_json(@argv.first)
      when "save" then save(@argv[0], @argv[1])
      when "flag" then flag_path(@argv[0], @argv[1])
      when "produce" then produce(@argv[0], @argv[1])
      when "bridge" then bridge
      when "init" then init(@argv.first)
      when "fix" then fix(@argv.first)
      when "ask" then ask(@argv.first)
      when "run" then run_requests
      when "serve" then serve(@argv.first)
      when "search" then search(@argv.first)
      when "nodes" then list_nodes
      when "help", "-h", "--help" then help
      else
        warn "unknown command: #{cmd}"
        help
        1
      end
    end

    private

    # Pull lens flags out of argv, leaving positionals: --role/--lens NAME,
    # --floor N, --strict (sugar for the reviewer lens). `=`-joined forms too.
    def parse_opts!
      opts = {}
      rest = []
      while (arg = @argv.shift)
        case arg
        when "--role", "--lens" then opts[:role] = @argv.shift
        when "--floor" then opts[:floor] = @argv.shift&.to_f
        when "--strict" then opts[:role] = "reviewer"
        when "--live" then opts[:live] = true
        when "--echo" then opts[:echo] = true
        when "--timeout" then opts[:timeout] = @argv.shift&.to_i
        when "--port" then opts[:port] = @argv.shift&.to_i
        when "--log" then opts[:log] = @argv.shift
        when "--session" then opts[:session] = @argv.shift
        when "--mode" then opts[:mode] = @argv.shift
        when /\A--mode=(.+)/ then opts[:mode] = Regexp.last_match(1)
        when "--type" then opts[:type] = @argv.shift
        when /\A--type=(.+)/ then opts[:type] = Regexp.last_match(1)
        when /\A--log=(.+)/ then opts[:log] = Regexp.last_match(1)
        when /\A--session=(.+)/ then opts[:session] = Regexp.last_match(1)
        when /\A--(?:role|lens)=(.+)/ then opts[:role] = Regexp.last_match(1)
        when /\A--floor=(.+)/ then opts[:floor] = Regexp.last_match(1).to_f
        when /\A--port=(.+)/ then opts[:port] = Regexp.last_match(1).to_i
        else rest << arg
        end
      end
      @argv = rest
      opts
    end

    # The lens selected by the flags (default unless --role/--strict/--floor).
    def lens
      @lens ||=
        begin
          base = Lens.preset(@opts[:role] || :default)
          @opts[:floor] ? base.with_floor(@opts[:floor]) : base
        rescue ArgumentError => e
          warn e.message
          Lens.new(name: :default)
        end
    end

    # One pinned clock per invocation: graph and columns see the same `now`.
    def now
      @now ||= Time.now
    end

    def explore(arg)
      workspace, node_id = target_for(arg, fixture_default: "src/orders.rb")
      unless node_id
        warn "no node matching #{arg.inspect}"
        list_nodes
        return 1
      end
      puts Renderers::Text.new.render(workspace.column_for(node_id, now: now))
      0
    end

    # Interactive Miller-column cascade. A real dir is indexed lazily; otherwise
    # defaults to the demo repo root.
    def walk(arg)
      # `session` means YOUR session when the bridge's log is here — rooted at
      # the live Session node, with the whole project one descend away through
      # its IN_PROJECT edge. The frozen demo keeps the name only when there is
      # nothing real to show (or ask for it by name: `hcol walk demo --live`).
      return walk_project(Dir.pwd, root: :session) if arg == "session" && File.exist?(bridge_log(Dir.pwd))

      arg = demo_name(arg)
      return walk_live_session if arg == "session" && @opts[:live]
      return walk_live_sessions if arg == "sessions" && @opts[:live]
      return walk_live_file(File.expand_path(arg)) if @opts[:live] && log_path?(arg)

      if @opts[:live] && (dir = plain_dir(arg))
        log = bridge_log(dir)
        return no_bridge_log(log) unless File.exist?(log)

        return walk_project(dir)
      end

      workspace, node_id = target_for(arg, fixture_default: "repo/")
      unless node_id
        warn "no node matching #{arg.inspect}"
        return 1
      end
      session = session_context_for(workspace.graph, node_id)
      TUI.new(Cascade.new(workspace, node_id, now: now, floor: @opts[:floor].to_f, session: session)).run
      0
    rescue TUI::NoTTY => e
      warn e.message
      warn "(use `hcol explore` for static output)"
      1
    end

    # The live agent session: seed the task + its driver, then let the TUI release
    # the rest of the script (proposes a change, touches files, runs the test) as
    # wall-clock elapses — the column grows under you. The guiding star, walkable.
    def walk_live_session
      feed = Providers::AgentSession.feed(now: now)
      graph = Graph.new
      feed.release(0.0, into: graph) # seed: the task and who is driving it exist at t0
      workspace = Workspace.new(graph: graph, lens: lens)
      cascade = Cascade.new(workspace, Providers::AgentSession.session_id, now: now, feed: feed,
                            floor: @opts[:floor].to_f, session: session_context(graph))
      TUI.new(cascade).run
      0
    rescue TUI::NoTTY => e
      warn e.message
      warn "(the live session needs an interactive terminal)"
      1
    end

    # The out-of-process producer: replay the agent session into an append-only
    # JSONL log in real time, the way a live agent would write events as it works.
    # Run this in one terminal and `hcol walk <file> --live` (or serve) in another —
    # the columns grow as lines land. They meet only at the file (single-writer
    # preserved; no shared memory, no threads).
    def produce(selector, path)
      selector = demo_name(selector)
      unless %w[session sessions].include?(selector) && path
        warn "usage: hcol produce <session|sessions> <path.jsonl>"
        return 1
      end
      script = producible_script(selector)
      warn "producing #{selector} -> #{path} (#{script.size} events; Ctrl-C to stop)"
      File.open(path, "w") { |io| LogProducer.new(script, io: io).run }
      warn "done"
      0
    rescue Interrupt
      warn "\nstopped"
      0
    end

    # The real agent bridge: append events for what an agent did, in a neutral
    # vocabulary a thin external hook feeds. One command per argv or stdin line
    # (`edit <path>`, `phase <name>`, `test ok|fail <cmd>`, `log <text>`, `done`),
    # each a Persistence line on the --log file that `walk/serve <log> --live` tails.
    def bridge
      path = @opts[:log]
      unless path
        warn "usage: hcol bridge --log <file.jsonl> [--session KEY] [<command…>]   (or pipe commands on stdin)"
        return 1
      end
      agent = AgentBridge.new(path: File.expand_path(path), session: @opts[:session] || "live")
      if @argv.empty?
        $stdin.each_line { |line| agent.apply(line) }
      else
        # One command per arg — what the help, the skill and STATUS have always
        # promised. This used to `join(" ")` every arg into a single command, so
        # `bridge "session k Title" "phase exploring"` silently made the phase part
        # of the title (found live: a Session named "Task: … phase exploring").
        # Quote each command; the hook passes exactly one.
        @argv.each { |command| agent.apply(command) }
      end
      0
    end

    # `hcol fix <suggestion-id>` — ask for a suggestion to be acted on (hc-bnh).
    #
    # Deliberately does NOT run anything. It appends one request event to the
    # bridge log and stops; a runner outside hcolumns decides whether to put an
    # agent on it. Two reasons, both load-bearing: the library stays agent-agnostic
    # (the runner is the outbound mirror of the inbound hook), and dispatching code
    # changes at somebody is not something a read-model should do behind your back.
    def fix(selector)
      found = selector && live_target_for(selector)
      node = found && found[0].graph.node(found[1])
      unless node && node.type == :Suggestion
        warn "usage: hcol fix <suggestion-id>   (an obj: id from a transcript's `advice` tab)"
        return 1
      end
      prompt = node.properties[:fix]
      unless prompt
        warn "#{node.properties[:name]}: reported for honesty, not action — there's no fix to hand off"
        return 1
      end

      log = bridge_log(Dir.pwd)
      AgentBridge.new(path: log, session: @opts[:session] || "live")
                 .apply("request fix #{node.id} #{prompt.gsub(/\s+/, ' ')}")
      puts "requested: #{node.properties[:name]}"
      puts "  → appended to #{log.sub("#{Dir.pwd}/", '')}. A runner tailing the log can pick it up;"
      puts "    nothing has run. `hcol json session` shows the REQUESTED edge."
      0
    end

    # `hcol ask "<prompt>"` — queue an LLM task with no special provenance. The
    # generic form `hcol fix` is a special case of: both write the same Request,
    # and the runner cannot tell them apart.
    def ask(prompt)
      if prompt.to_s.strip.empty?
        warn 'usage: hcol ask "<prompt>"   (queues a request; `hcol run` executes it)'
        return 1
      end

      log = bridge_log(Dir.pwd)
      AgentBridge.new(path: log, session: @opts[:session] || "live")
                 .apply("request ask - #{prompt.to_s.gsub(/\s+/, ' ')}")
      puts "queued: #{prompt.to_s.strip[0, 60]}"
      puts "  → nothing has run. `hcol run` executes outstanding requests."
      0
    end

    # `hcol run` — execute outstanding requests (hc-4s4). The connector: the log
    # carries intent, this puts an LLM on it, and the answer returns as a node.
    #
    # Outstanding is a question for the GRAPH — a Request with no LLMTask hanging
    # off it — not a cursor file that can drift out of sync with the log it
    # describes. Replay is safe by construction: a replayed log contains the task
    # too, so nothing looks outstanding and nothing re-fires.
    def run_requests
      workspace, _root = composed_target(Dir.pwd, root: :session)
      pending = LLMTaskRunner.outstanding(workspace.graph)
      if pending.empty?
        puts "nothing outstanding. (`hcol fix <suggestion>` or `hcol ask \"…\"` queues work.)"
        return 0
      end

      runner = LLMTaskRunner.new(strategy: run_strategy, log: bridge_log(Dir.pwd),
                                 session: @opts[:session] || "live")
      puts "#{pending.size} outstanding request#{pending.size == 1 ? '' : 's'}:"
      pending.each { |r| puts "  · #{r.properties[:kind]}: #{r.properties[:prompt].to_s[0, 62]}" }
      runner.submit_outstanding(workspace.graph)
      puts "\ndispatched. watch them in `hcol serve .` — each task flips ◌ → ◐ → ✓ in place."
      runner.run_to_completion(timeout: (@opts[:timeout] || 600).to_i)
      runner.tasks.each_value { |t| puts "  #{t.state == :done ? '✓' : '✗'} #{t.prompt.to_s[0, 62]}" }
      0
    end

    # The default is a real agent in a real pane you can `tmux attach` to and take
    # over — the reason to want tmux over a headless call. --echo swaps in the
    # double, so the wiring can be exercised without spending a token.
    def run_strategy
      return Strategies::Echo.new if @opts[:echo]

      Strategies::TmuxClaudeCode.new(root: Dir.pwd, hcol_bin: ENV.fetch("HCOL_BIN", "hcol"))
    end

    # `hcol init [dir]` — install the bridge hook + skill into any repo (hc-ouk),
    # so the live-session stratum is a feature of the gem, not of this repo.
    def init(dir)
      root = File.expand_path(dir || ".")
      unless File.directory?(root)
        warn "usage: hcol init [dir]   (dir must exist; default: .)"
        return 1
      end

      results = Initializer.new(root).run
      report_init(root, results)
      0
    rescue Initializer::Error => e
      warn "hcol init: #{e.message}"
      1
    end

    GLYPHS = { written: "✓", updated: "✓", merged: "✓", unchanged: "=" }.freeze

    def report_init(root, results)
      puts "hcolumns → #{root}"
      results.each do |r|
        path = r.path.sub("#{root}/", "")
        line = "  #{GLYPHS[r.status]} #{path.ljust(38)} #{r.status}"
        line += " (#{r.note})" if r.note
        puts line
      end
      puts <<~TXT

        Start a session in this repo, then watch it:
          hcol serve .            the composed graph — files, git, and your session
          hcol walk . --live      …in the terminal
      TXT
    end

    # A timed [{ after:, kind:, payload: }] script for the producer. The session is
    # already timed; the sessions index is instantaneous (all at t0), delivered live.
    def producible_script(selector)
      case selector
      when "session" then Providers::AgentSession.script(now: now)
      when "sessions"
        log = EventLog.new
        Providers::AgentSession.sessions_graph(now: now, graph: Graph.new(log: log))
        log.events.map { |e| { after: 0.0, kind: e.kind, payload: e.payload } }
      end
    end

    # Follow an append-only log a producer is writing: tail it into a projection
    # and walk the growing cascade. The web analogue is live_web_file_app.
    # The TUI over the same composed graph `serve` offers: the directory's pull
    # strata plus the bridge log's session, one cascade. Single-threaded, so the
    # one workspace is fine (no AppSource needed here).
    def walk_project(dir, root: :dir)
      workspace, start, feed, session = composed_target(dir, root: root)
      cascade = Cascade.new(workspace, start, now: now, feed: feed,
                            floor: @opts[:floor].to_f, session: session)
      TUI.new(cascade).run
      0
    rescue TUI::NoTTY => e
      warn e.message
      warn "(the live walk needs an interactive terminal)"
      1
    end

    def walk_live_file(path)
      reader = TailReader.new(path)
      graph = Graph.new
      root = await_root(reader, graph)
      return no_events(path) unless root

      workspace = Workspace.new(graph: graph, lens: lens)
      cascade = Cascade.new(workspace, root, now: now, feed: reader,
                            floor: @opts[:floor].to_f, session: session_context_for(graph, root))
      TUI.new(cascade).run
      0
    rescue TUI::NoTTY => e
      warn e.message
      warn "(the live tail needs an interactive terminal)"
      1
    end

    # Drain the tail until the log's root node lands (the producer writes it first),
    # so we have something to open the first column on. Gives up after `timeout` so
    # a walk with no producer running fails cleanly instead of hanging.
    def await_root(reader, graph, timeout: 5.0)
      deadline = now_wall + timeout
      loop do
        reader.release(into: graph)
        root = Persistence.root_id(reader.log)
        return root if root
        return nil if now_wall > deadline

        sleep 0.05
      end
    end

    def now_wall
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def no_events(path)
      warn "no events yet in #{path} — is a producer writing it? (try: hcol produce session #{path})"
      1
    end

    def log_path?(arg)
      arg&.end_with?(".jsonl")
    end

    # The phase-bearing session a walk sits in, so modes follow the agent's work.
    def session_context(graph)
      SessionContext.new(graph: graph, node_id: Providers::AgentSession.session_id)
    end

    # A SessionContext for a root that declares a `:phase` (the Session node, live
    # or reloaded from a snapshot) — nil otherwise. Keying on the phase property,
    # not a magic arg, is what lets a loaded `.jsonl` session drive modes too.
    def session_context_for(graph, node_id)
      node = graph.node(node_id)
      return nil unless node&.properties&.key?(:phase)

      SessionContext.new(graph: graph, node_id: node_id)
    end

    # The sessions list with the newest session streaming: the index + the older
    # sessions are present from the start; descend into the live one to watch its
    # route grow under you.
    def walk_live_sessions
      live_key = Providers::AgentSession::SESSIONS.first[:key]
      graph = Providers::AgentSession.sessions_graph(now: now, live_key: live_key)
      feed = Providers::AgentSession.feed(now: now)
      feed.release(0.0, into: graph) # seed the live session's t0 onto its shell node
      workspace = Workspace.new(graph: graph, lens: lens)
      cascade = Cascade.new(workspace, Providers::AgentSession.index_id, now: now, feed: feed, floor: @opts[:floor].to_f)
      TUI.new(cascade).run
      0
    rescue TUI::NoTTY => e
      warn e.message
      warn "(the live session needs an interactive terminal)"
      1
    end

    # Returns [workspace, node_id]. A real filesystem path is indexed via the
    # filesystem/naming providers (the selected node is that path); otherwise the
    # arg selects into the demo graph.
    # The contextual inspector: everything about a node and how it got here.
    def inspect_node(arg)
      workspace, node_id = target_for(arg, fixture_default: "src/orders.rb")
      unless node_id
        warn "no node matching #{arg.inspect}"
        return 1
      end
      workspace.expand(node_id, now: now) # so a real path has its edges
      puts Renderers::Detail.new.node(workspace.node(node_id), workspace.graph, lens: lens, now: now)
      0
    end

    # The web front-end's data contract, on stdout: the same Panel+ranked-modes a
    # browser (or the TUI) would render for a node, as JSON. Proves the cross-
    # front-end contract end-to-end without a server.
    def emit_json(arg)
      app, node_id = web_app_for(arg, fixture_default: "src/orders.rb")
      unless node_id
        warn "no node matching #{arg.inspect}"
        return 1
      end
      puts JSON.pretty_generate(app.panel(node_id, mode: @opts[:mode]))
      0
    end

    # Snapshot a session's event log to JSONL on disk — the mound persists. The
    # log is the source of truth, so this is all it takes to reload a walkable
    # session later (`hcol walk <file.jsonl>`); the graph re-projects on load.
    def save(selector, path)
      unless path
        warn "usage: hcol save <session|sessions> <path.jsonl>"
        return 1
      end
      log = persistable_log(demo_name(selector))
      unless log
        warn "don't know how to snapshot #{selector.inspect} (try: session | sessions)"
        return 1
      end
      File.open(path, "w") { |io| Persistence.dump(log, io) }
      warn "wrote #{log.version} events to #{path}"
      0
    end

    # The full event log behind a demo selector, folded whole (frozen). For the
    # session that means releasing the entire timed script into a Feed's log; for
    # the index, a log-backed graph so every HAS_SESSION + route event is recorded.
    def persistable_log(selector)
      case selector
      when "session"
        feed = Providers::AgentSession.feed(now: now)
        feed.release(Float::INFINITY, into: Graph.new)
        feed.log
      when "sessions"
        log = EventLog.new
        Providers::AgentSession.sessions_graph(now: now, graph: Graph.new(log: log))
        log
      end
    end

    # Serve the columns over HTTP: a browser renders the same panels the TUI does,
    # descending by fetching the next node's JSON. With `--live` on the session /
    # sessions demo the column grows in the browser as the agent works (the web
    # analogue of `walk session --live`). The second front-end.
    def serve(arg)
      if @opts[:live] && log_path?(arg)
        path = File.expand_path(arg)
        server = tail_server(path) || (return no_events(arg))
        return run_server(server, "tailing #{display_path(path)} (live)")
      end

      if (dir = plain_dir(arg))
        # A real directory serves ONE composed graph: every pull stratum the
        # dir offers (fs/git/beads/ruby/flags), and when the agent bridge's
        # log is there, its session folds in live too — mounted under the
        # root at serve time (BridgeMount), streamed over SSE.
        log = bridge_log(dir)
        if File.exist?(log)
          return run_server(project_server(dir),
                            "serving #{display_path(dir)} (live: tailing #{display_path(log)})")
        end
        return no_bridge_log(log) if @opts[:live]
      end

      # `session` roots the same composed graph at the live Session node when
      # the bridge's log is here (its IN_PROJECT edge walks back out to the
      # files/git/beads strata); the frozen demo keeps the name only when
      # there's nothing real to show — or ask for it: `hcol serve demo --live`.
      if arg == "session" && File.exist?(bridge_log(Dir.pwd))
        return run_server(project_server(Dir.pwd, root: :session),
                          "serving the live session (tailing #{display_path(bridge_log(Dir.pwd))})")
      end

      arg = demo_name(arg)
      app =
        if @opts[:live] && %w[session sessions].include?(arg)
          live_web_app(arg)
        else
          static, node_id = web_app_for(arg, fixture_default: "repo/")
          return missing(arg) unless node_id

          static
        end
      server = Web::Server.new(app, port: @opts[:port] || 4567)
      run_server(server, server.live? ? "serving (live)" : "serving")
    end

    def run_server(server, banner)
      server.start { |s| warn "hcolumns #{banner} on http://#{s.host}:#{s.port}  (Ctrl-C to stop)" }
      0
    rescue Interrupt
      warn "\nstopped"
      0
    end

    # The one-server composition: ONE shared App behind a lock (AppSource::Locked).
    # Share-nothing can't serve this graph — the pull strata (fs/git/beads) expand
    # lazily into it, and a node id minted by one request's descent is an identity
    # digest a fresh graph can't resolve; the expansion must accrete somewhere all
    # connections can see. The push stratum (the bridge log's tail) folds into the
    # same graph, mounted under the root by BridgeMount.
    def project_server(dir, root: :dir)
      build = lambda do
        # Re-pin the clock per projection: a long-running server otherwise does
        # recency/decay math against its boot time. Safe: the builder only runs
        # under the Refreshing lock (and once here, before threads exist).
        @now = nil
        workspace, start, feed, session = composed_target(dir, root: root)
        Web::App.new(workspace: workspace, root_id: start, now: now,
                     session: session, feed: feed)
      end
      apps = Web::AppSource::Refreshing.new(build, probe: project_probe(dir))
      Web::Server.new(apps: apps, streaming: true, port: @opts[:port] || 4567)
    end

    # A cheap fingerprint of the pull sources — sits on the request path
    # (throttled), so file stats only: git's reflog head (moves on every
    # commit/checkout/reset, packed-refs-proof), the beads storage dir's
    # entries, and the served root's own mtime (top-level creates). The bridge
    # log is deliberately NOT here — it streams; re-projecting per event would
    # thrash. Deeper fs changes ride along with the next probe hit.
    def project_probe(dir)
      repo = Providers::Git.repo_root(dir)
      beads_root = Providers::Beads.available? && Providers::Beads.root_for(dir)
      beads_dir = beads_root && File.join(beads_root, ".beads") # root_for is the PROJECT root
      lambda do
        parts = [stat_fingerprint(dir)]
        parts << stat_fingerprint(File.join(repo, ".git", "logs", "HEAD")) if repo
        if beads_dir && File.directory?(beads_dir)
          Dir.children(beads_dir).sort.each do |entry|
            next if entry == "backup" # bd's backup blobs churn without data changes

            parts << stat_fingerprint(File.join(beads_dir, entry))
          end
        end
        parts
      end
    end

    def stat_fingerprint(path)
      stat = File.stat(path)
      [path, stat.mtime.to_f, stat.size]
    rescue SystemCallError
      [path, nil]
    end

    def missing(arg)
      warn "no node matching #{arg.inspect}"
      1
    end

    # `demo`/`demos` are the explicit names for the frozen demo selectors, so
    # the demo stays reachable now that a real project claims `session`.
    def demo_name(arg)
      { "demo" => "session", "demos" => "sessions" }[arg] || arg
    end

    # A real-directory selector. The literal `session`/`sessions` selectors keep
    # their demo meaning; a bare `hcol serve`/`hcol walk` keeps the demo default
    # unless --live says "my project, here" (then it means the cwd).
    def plain_dir(arg)
      return nil if %w[session sessions].include?(arg)
      return (@opts[:live] ? Dir.pwd : nil) if arg.nil?

      path = File.expand_path(arg)
      File.directory?(path) ? path : nil
    end

    # Where the agent bridge's hook writes its accreting log for a directory.
    # The hook writes at the project root, so serving a subdirectory looks
    # upward to the repo root when the dir itself has no log.
    def bridge_log(dir)
      local = File.join(dir, ".hcolumns", "live.jsonl")
      return local if File.exist?(local)

      repo = Providers::Git.repo_root(dir)
      repo ? File.join(repo, ".hcolumns", "live.jsonl") : local
    end

    # The composed project pieces: [workspace, start_id, feed, session_context].
    # One graph holding every stratum; `root:` picks where the walk begins —
    # :dir (the directory) or :session (the bridge log's live session; falls
    # back to the directory until a session has landed).
    def composed_target(dir, root: :dir)
      workspace, dir_id = directory_target(dir)
      feed = BridgeMount.new(TailReader.new(bridge_log(dir)), root_id: dir_id, now: now)
      feed.release(into: workspace.graph) # catch up before the first answer
      session = feed.session_id && session_context_for(workspace.graph, feed.session_id)
      start = (root == :session && feed.session_id) || dir_id
      [workspace, start, feed, session]
    end

    # A path shortened for banners: relative to the cwd when it lives under it.
    def display_path(path)
      return "." if path == Dir.pwd

      pwd = "#{Dir.pwd}/"
      path.start_with?(pwd) ? path.delete_prefix(pwd) : path
    end

    def no_bridge_log(log)
      warn "no bridge log at #{log}"
      warn "(`hcol init` wires the agent hook into this repo, and it appends as the agent works —"
      warn " or write one by hand: hcol bridge --log #{log} \"turn hello\" \"log first event\")"
      1
    end

    # A live web App over the agent session: the Feed releases events as wall-clock
    # elapses (pumped per request), so the browser's columns grow. Mirrors the
    # walk_live_session / walk_live_sessions seeding.
    def live_web_app(arg)
      feed = Providers::AgentSession.feed(now: now)
      if arg == "sessions"
        live_key = Providers::AgentSession::SESSIONS.first[:key]
        graph = Providers::AgentSession.sessions_graph(now: now, live_key: live_key)
        feed.release(0.0, into: graph)
        Web::App.new(workspace: Workspace.new(graph: graph, lens: lens),
                     root_id: Providers::AgentSession.index_id, now: now, feed: feed)
      else
        graph = Graph.new
        feed.release(0.0, into: graph)
        Web::App.new(workspace: Workspace.new(graph: graph, lens: lens),
                     root_id: Providers::AgentSession.session_id, now: now,
                     session: session_context(graph), feed: feed)
      end
    end

    # A streaming web server tailing a producer's log. Each connection builds its
    # OWN App (a fresh TailReader over the shared read-only file), so a long-lived
    # /events stream and the /panel fetches share no mutable state — lock-free, the
    # log-is-truth property of layer 17 extended to many in-process readers. nil if
    # no root arrives (no producer running yet).
    def tail_server(path)
      root = await_root(TailReader.new(path), Graph.new)
      return nil unless root

      the_lens = lens # capture once — the factory runs on many connection threads
      the_now = now
      factory = lambda do
        graph = Graph.new
        Web::App.new(workspace: Workspace.new(graph: graph, lens: the_lens), root_id: root,
                     now: the_now, session: SessionContext.new(graph: graph, node_id: root),
                     feed: TailReader.new(path))
      end
      Web::Server.new(app_factory: factory, streaming: true, port: @opts[:port] || 4567)
    end

    # Builds [Web::App, root_id] for a node selector, wiring the session context
    # when walking the agent session so the browser's auto modes follow the phase.
    def web_app_for(arg, fixture_default:)
      workspace, node_id = target_for(arg, fixture_default: fixture_default)
      return [nil, nil] unless node_id

      session = session_context_for(workspace.graph, node_id)
      app = Web::App.new(workspace: workspace, root_id: node_id, now: now, session: session)
      [app, node_id]
    end

    def target_for(arg, fixture_default:)
      if (live = live_target_for(arg))
        return live
      end

      arg = demo_name(arg)
      return [sessions_workspace, Providers::AgentSession.index_id] if arg == "sessions"
      return [session_workspace, Providers::AgentSession.session_id] if arg == "session"

      path = arg && File.expand_path(arg)
      if path && File.file?(path) && path.end_with?(".jsonl")
        log = File.open(path, "r") { |io| Persistence.load(io) }
        workspace = Workspace.new(graph: log.project, lens: lens)
        [workspace, Persistence.root_id(log)]
      elsif path && File.exist?(path)
        workspace, node_id = directory_target(path)
        # One-shot reads see the composed graph too: the session stratum folds
        # in beside the pull strata (a file's TOUCHED_BY, the change-set's
        # VERIFIED_BY). Only a directory gets the seam edges — hanging
        # HAS_SESSION under a queried file would be noise.
        fold_bridge_log(workspace, path, seam_root_id: File.directory?(path) ? node_id : nil)
        [workspace, node_id]
      else
        [fixture_workspace, resolve_in_fixture(arg || fixture_default)]
      end
    end

    # `hcol search <term> [--type T]` — find nodes by name/path substring across
    # every stratum of the cwd's composed graph. Prints one line per match:
    # id, type, name, and the path when the node carries one — the id/path is
    # what `hcol json` descends from (the agent skill's missing read).
    def search(term)
      if term.nil? || term.strip.empty?
        warn "usage: hcol search <term> [--type Session|Bead|SourceFile|TestRun|…]"
        return 1
      end

      workspace, root_id = directory_target(Dir.pwd)
      fold_bridge_log(workspace, Dir.pwd, seam_root_id: root_id)
      searcher = Searcher.new(workspace, now: now)
      matches = searcher.find(term, from: root_id, type: @opts[:type])
      matches.each do |node|
        path = node.properties[:path]
        suffix = path && path.to_s != node.name.to_s ? "  #{display_path(path.to_s)}" : ""
        puts "#{node.id}  #{node.type}  #{node.name}#{suffix}"
      end
      warn "(node cap hit — the search did NOT cover everything; narrow with --type)" if searcher.capped?
      warn "no nodes matching #{term.inspect}" if matches.empty?
      matches.empty? ? 1 : 0
    end

    # One-shot selectors into the REAL project, when the bridge's log is here:
    # `session` roots at the live session; an `obj:` id resolves into the
    # composed graph. Log-borne ids replay deterministically (same identity =>
    # same id in every process), so an obj: id printed by one invocation's JSON
    # is addressable by the next; file nodes only exist once their parent has
    # expanded — address files by path instead.
    def live_target_for(arg)
      return nil unless arg == "session" || arg&.start_with?("obj:")
      return nil unless File.exist?(bridge_log(Dir.pwd))

      workspace, start, feed, = composed_target(Dir.pwd, root: :session)
      if arg == "session"
        feed.session_id ? [workspace, start] : nil
      elsif (found = resolve_shallow(workspace, arg))
        [workspace, found]
      end
    end

    # An obj: id beyond the log replay lives in the pull strata and only exists
    # once its parent expands. Cheap ladder: the root, then its first ring (the
    # beads index -> its beads, branches -> commits), then — the same
    # materialization `search` uses, so anything a search printed is
    # addressable — the full capped expansion.
    def resolve_shallow(workspace, id)
      return id if workspace.node(id)

      root_id = Providers::Filesystem.node_for(Dir.pwd).id
      workspace.expand(root_id, now: now)
      return id if workspace.node(id)

      workspace.graph.edges_from(root_id).map(&:target_id).each { |nid| workspace.expand(nid, now: now) }
      return id if workspace.node(id)

      Searcher.new(workspace, now: now).expand_all(root_id)
      workspace.node(id) ? id : nil
    end

    def fold_bridge_log(workspace, path, seam_root_id: nil)
      dir = File.directory?(path) ? path : File.dirname(path)
      log = bridge_log(dir)
      return unless File.exist?(log)

      reader = TailReader.new(log)
      feed = seam_root_id ? BridgeMount.new(reader, root_id: seam_root_id, now: now) : reader
      feed.release(into: workspace.graph)
    end

    # [Workspace, root_id] over a real path: every pull stratum the path offers.
    def directory_target(path)
      providers = [Providers::Filesystem.new, Providers::NamingRules.new]
      repo = Providers::Git.repo_root(path)
      providers << Providers::Git.new(repo) if repo
      beads_root = Providers::Beads.available? && Providers::Beads.root_for(path)
      providers << Providers::Beads.new(beads_root) if beads_root
      root = repo || (File.directory?(path) ? path : File.dirname(path))
      providers << Providers::RubyCode.new(root)
      # The context stratum is stateless — a Transcript node carries its own path,
      # so the provider needs no root and the class itself is the instance.
      providers << Providers::Transcript
      providers << Providers::ContextAdvice
      # A real walk is log-backed (providers record as they expand) and carries
      # the accreting flag store: prior sessions' judgments replay in, and new
      # flags append as they happen.
      workspace = Workspace.new(graph: Graph.new(log: EventLog.new), providers: providers,
                                lens: lens, flag_store: flag_store_for(root))
      node = workspace.add_node(Providers::Filesystem.node_for(path))
      workspace.replay_flags
      [workspace, node.id]
    end

    # The flag store for a walked root — where this repo's judgments accrete.
    def flag_store_for(root)
      FlagStore.new(File.join(root, ".hcolumns", "flags.jsonl"))
    end

    # `hcol flag <path> <up|down|exclude|clear>` — flag a file/dir without
    # opening the TUI (the bulk entry point; the walk replays it next time).
    def flag_path(path_arg, level)
      level = level&.to_sym
      path = path_arg && File.expand_path(path_arg)
      unless path && File.exist?(path) && Graph::FLAG_LEVELS.include?(level)
        warn "usage: hcol flag <path> <up|down|exclude|clear>"
        return 1
      end

      node = Providers::Filesystem.node_for(path)
      root = Providers::Git.repo_root(path) || (File.directory?(path) ? path : File.dirname(path))
      flag_store_for(root).append(node_id: node.id, level: level, by: ENV["USER"] || "user", at: now)
      puts "⚑ #{level} #{path_arg}"
      0
    end

    def fixture_workspace
      @fixture_workspace ||= Workspace.new(graph: Providers::InMemoryFixture.build(now: now), lens: lens)
    end

    # The frozen agent-session demo (the guiding-star substrate). Selected by the
    # literal arg `session`: `hcol explore session` / `hcol walk session`.
    def session_workspace
      @session_workspace ||= Workspace.new(graph: Providers::AgentSession.build(now: now), lens: lens)
    end

    # The frozen sessions index: every session listed, each descendable.
    def sessions_workspace
      @sessions_workspace ||= Workspace.new(graph: Providers::AgentSession.sessions_graph(now: now), lens: lens)
    end

    # Resolve a demo selector to a node id: exact id, exact name, then substring.
    def resolve_in_fixture(selector)
      graph = fixture_workspace.graph
      graph.node(selector)&.id ||
        graph.nodes.find { |n| n.name.to_s == selector }&.id ||
        graph.nodes.find { |n| n.name.to_s.include?(selector) }&.id
    end

    def list_nodes
      fixture_workspace.graph.nodes.sort_by { |n| n.name.to_s }.each do |n|
        puts "#{n.id}  #{n.type}  #{n.name}"
      end
      0
    end

    def help
      puts <<~TXT
        hcol — harris columns

          hcol init [dir]            wire the agent bridge into a repo: writes the hook +
                                     the `hcol` agent skill into .claude/ and merges the
                                     hook events into .claude/settings.json (keeping any
                                     hooks already there). Idempotent; re-run after a gem
                                     upgrade to refresh. Then `hcol serve .` shows that
                                     repo's sessions live
          hcol explore [node|path]   print the ranked column for a node or a real file/dir
                                     (default: src/orders.rb in the demo graph)
          hcol walk [dir|path]       interactively walk the cascade (arrows/hjkl;
                                     Tab cycles the column's modes, [ ] move the confidence floor,
                                     + - x u flag the selection up/down/excluded/clear)
                                     (a real dir is indexed lazily; default: demo repo root)
          hcol flag <path> <up|down|exclude|clear>
                                     flag a file/dir without the TUI; persists to
                                     .hcolumns/flags.jsonl and replays on every walk
          hcol serve session         YOUR live session as the root (needs .hcolumns/live.jsonl):
                                     descend IN_PROJECT to reach the files/git/beads strata
          hcol walk session          …same, in the terminal
          hcol walk demos --live     the frozen DEMO: the sessions list, newest streaming as it "works"
          hcol explore demo          the demo route (Task→change→files→test→log)
          hcol walk demo --live      watch the demo session's column grow
                                     (`session`/`sessions` still mean the demo where no bridge log exists)
          hcol ask "<prompt>"        queue an LLM task (a Request in the log). Nothing runs
          hcol run [--echo]          execute every OUTSTANDING request — a Request with no task
                                     yet. Drives Claude Code in a tmux pane you can attach to and
                                     take over; each task flips ◌ → ◐ → ✓ in the columns as it goes.
                                     --echo uses the test double (no tokens); --timeout N (default 600)
          hcol fix <suggestion-id>   ask for a suggestion (from a transcript's `advice` tab) to be
                                     acted on: appends ONE request event to the bridge log and stops.
                                     Nothing runs — a runner tailing the log decides whether to put an
                                     agent on it, and its work lands back in the graph as a ProposedChange
          hcol search <term>         find nodes by name/path substring across every stratum of
                                     the cwd's composed graph (--type Bead|SourceFile|TestRun|…);
                                     prints id · type · name · path — feed the id or path to json
          hcol inspect [node|path]   everything about a node: data, provenance, confidence math
          hcol json [node|path]      the node's panel + ranked modes as JSON (the web data contract)
                                     --mode M picks a tab (turns, diff, details, blame, …); with a
                                     bridge log here, `session` and obj: ids resolve into the REAL
                                     composed graph (log-borne ids are stable across invocations;
                                     address files by path) — the agent-readable surface
          hcol save <session|sessions> <file.jsonl>
                                     snapshot a session's event log to disk (the mound persists)
          hcol explore|walk|serve <file.jsonl>
                                     reload a snapshot: the graph re-projects from the log
          hcol produce <session|sessions> <file.jsonl>
                                     out-of-process producer: append events to the log in real time
          hcol bridge --log <file.jsonl> [--session KEY] [<command>]
                                     real agent bridge: append events for what an agent did, in a
                                     neutral vocab (turn <label> · edit <path> · phase <name> ·
                                     test start|ok|fail <cmd> · usage in=N out=N … ·
                                     log <text> · done) — one per arg or
                                     stdin line. A thin hook feeds it (.claude/hooks/); watch with
                                     walk/serve --live; the session's `turns` tab groups work per turn
          hcol serve <dir>           ONE server over the project's composed graph: files, git,
                                     beads, ruby — and when the agent bridge's log is there
                                     (.hcolumns/live.jsonl), its session too, streamed over SSE:
                                     a HAS_SESSION section on the root; descend for turns,
                                     the change-set, its files and TestRuns
          hcol serve --live          …same for the cwd (bare `hcol serve` keeps the demo)
          hcol walk [dir] --live     …same composed graph, in the terminal
          hcol walk <file.jsonl> --live    tail any producer's log; the cascade grows as events land
          hcol serve <file.jsonl> --live   …same, in a browser (run `produce` alongside)
          hcol serve [node|path]     serve the columns over HTTP; walk them in a browser (--port N)
          hcol serve demo --live     …with the demo session streaming: columns grow as it "works"
          hcol nodes                 list nodes in the demo graph
          hcol help                  this help

        in walk, each column has tabs (modes) for its node: an auto mode by node type
        plus alternatives — Tab cycles them, i jumps to the details tab (data + how it
        got here + confidence math). A ProposedChange opens on a diff facet. A file in a
        git repo has a `blame` tab: each line tagged with the commit that last touched
        it — descend a line to that commit's change to the file (a scoped diff), then
        the "full commit" row to zoom out to the whole diff + its history.

        lens flags (on explore/walk):
          --role NAME                #{Lens.names.join(' | ')}
          --strict                   sugar for --role reviewer
          --floor N                  hide edges below confidence N (0.0–1.0)
      TXT
      0
    end
  end
end
