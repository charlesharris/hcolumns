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
        when /\A--(?:role|lens)=(.+)/ then opts[:role] = Regexp.last_match(1)
        when /\A--floor=(.+)/ then opts[:floor] = Regexp.last_match(1).to_f
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
      return walk_live_session if arg == "session" && @opts[:live]
      return walk_live_sessions if arg == "sessions" && @opts[:live]

      workspace, node_id = target_for(arg, fixture_default: "repo/")
      unless node_id
        warn "no node matching #{arg.inspect}"
        return 1
      end
      TUI.new(Cascade.new(workspace, node_id, now: now, floor: @opts[:floor].to_f)).run
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
      cascade = Cascade.new(workspace, Providers::AgentSession.session_id, now: now, feed: feed, floor: @opts[:floor].to_f)
      TUI.new(cascade).run
      0
    rescue TUI::NoTTY => e
      warn e.message
      warn "(the live session needs an interactive terminal)"
      1
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

    def target_for(arg, fixture_default:)
      return [sessions_workspace, Providers::AgentSession.index_id] if arg == "sessions"
      return [session_workspace, Providers::AgentSession.session_id] if arg == "session"

      path = arg && File.expand_path(arg)
      if path && File.exist?(path)
        providers = [Providers::Filesystem.new, Providers::NamingRules.new]
        repo = Providers::Git.repo_root(path)
        providers << Providers::Git.new(repo) if repo
        root = repo || (File.directory?(path) ? path : File.dirname(path))
        providers << Providers::RubyCode.new(root)
        workspace = Workspace.new(providers: providers, lens: lens)
        root = workspace.add_node(Providers::Filesystem.node_for(path))
        [workspace, root.id]
      else
        [fixture_workspace, resolve_in_fixture(arg || fixture_default)]
      end
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

          hcol explore [node|path]   print the ranked column for a node or a real file/dir
                                     (default: src/orders.rb in the demo graph)
          hcol walk [dir|path]       interactively walk the cascade (arrows/hjkl;
                                     Tab cycles the column's modes, [ ] move the confidence floor)
                                     (a real dir is indexed lazily; default: demo repo root)
          hcol walk sessions         walk the list of agent sessions, descend into any
          hcol walk sessions --live  …with the newest session streaming as it works
          hcol explore session       the agent-session route (Task→change→files→test→log)
          hcol walk session          walk that route interactively
          hcol walk session --live   watch one session's column grow as the agent "works"
          hcol inspect [node|path]   everything about a node: data, provenance, confidence math
          hcol nodes                 list nodes in the demo graph
          hcol help                  this help

        in walk, each column has tabs (modes) for its node: an auto mode by node type
        plus alternatives — Tab cycles them, i jumps to the details tab (data + how it
        got here + confidence math). A ProposedChange opens on a diff facet.

        lens flags (on explore/walk):
          --role NAME                #{Lens.names.join(' | ')}
          --strict                   sugar for --role reviewer
          --floor N                  hide edges below confidence N (0.0–1.0)
      TXT
      0
    end
  end
end
