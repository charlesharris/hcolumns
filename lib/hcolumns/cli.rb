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
      workspace, node_id = target_for(arg, fixture_default: "repo/")
      unless node_id
        warn "no node matching #{arg.inspect}"
        return 1
      end
      TUI.new(Cascade.new(workspace, node_id, now: now)).run
      0
    rescue TUI::NoTTY => e
      warn e.message
      warn "(use `hcol explore` for static output)"
      1
    end

    # Returns [workspace, node_id]. A real filesystem path is indexed via the
    # filesystem/naming providers (the selected node is that path); otherwise the
    # arg selects into the demo graph.
    def target_for(arg, fixture_default:)
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
                                     r cycles the lens, [ ] move the confidence floor)
                                     (a real dir is indexed lazily; default: demo repo root)
          hcol nodes                 list nodes in the demo graph
          hcol help                  this help

        lens flags (on explore/walk):
          --role NAME                #{Lens.names.join(' | ')}
          --strict                   sugar for --role reviewer
          --floor N                  hide edges below confidence N (0.0–1.0)
      TXT
      0
    end
  end
end
