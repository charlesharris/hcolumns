# frozen_string_literal: true

module HColumns
  # A thin client over the graph + column builder. Layer one talks to the
  # in-memory fixture; later layers swap in real providers behind the same calls.
  class CLI
    def self.run(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      cmd = @argv.shift || "explore"
      case cmd
      when "explore" then explore(@argv.first)
      when "nodes" then list_nodes
      when "help", "-h", "--help" then help
      else
        warn "unknown command: #{cmd}"
        help
        1
      end
    end

    private

    # One pinned clock per invocation: graph and column see the same `now`.
    def now
      @now ||= Time.now
    end

    def graph
      @graph ||= Providers::InMemoryFixture.build(now: now)
    end

    def explore(selector)
      node_id = resolve(selector)
      unless node_id
        warn "no node matching #{selector.inspect}"
        list_nodes
        return 1
      end
      column = ColumnBuilder.new(graph).build(node_id, now: now)
      puts Renderers::Text.new.render(column)
      0
    end

    # Resolve a selector to a node id: nil => the demo default; else exact id,
    # exact name, then substring.
    def resolve(selector)
      return Providers::InMemoryFixture.orders_id if selector.nil?

      graph.node(selector)&.id ||
        graph.nodes.find { |n| n.name.to_s == selector }&.id ||
        graph.nodes.find { |n| n.name.to_s.include?(selector) }&.id
    end

    def list_nodes
      graph.nodes.sort_by { |n| n.name.to_s }.each do |n|
        puts "#{n.id}  #{n.type}  #{n.name}"
      end
      0
    end

    def help
      puts <<~TXT
        hcol — harris columns (layer one)

          hcol explore [node]   print the ranked column for a node
                                (node = id, name, or substring; default: src/orders.rb)
          hcol nodes            list nodes in the demo graph
          hcol help             this help
      TXT
      0
    end
  end
end
