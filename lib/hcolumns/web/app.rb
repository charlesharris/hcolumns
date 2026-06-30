# frozen_string_literal: true

module HColumns
  module Web
    # The web front-end's application core, with no HTTP in it. Given a Workspace,
    # it answers "the renderable data for this node (optionally on this tab)" using
    # the very same ModeResolver the TUI drives — so the browser and the terminal
    # agree on which tabs a node has and which is auto, by construction.
    #
    # This is the consumer the orphaned Serializer was missing: it turns a node id
    # into a Panel (via the resolver) and hands that to the Serializer. The result
    # is a plain JSON-able Hash; turning it into bytes (HTTP, a file, stdout) is
    # someone else's job. The Workspace is stateful and expands lazily, so holding
    # one App across many panel() calls is exactly a descend-as-you-go cascade:
    # each call pulls the node's neighbors into the graph, so the next call's
    # target_id is already a real node.
    class App
      attr_reader :root_id

      # `feed` makes the App *live*: a duck-typed event Feed (release(elapsed, into:)
      # / log / done?) whose due events are pumped into the graph on demand, the web
      # analogue of the TUI's tick-on-IO-timeout. `clock` is the injectable wall
      # clock (real time by default, a lambda in tests) used to measure elapsed.
      def initialize(workspace:, root_id:, now:, session: nil, resolver: ModeResolver.new,
                     feed: nil, clock: -> { Time.now })
        @workspace = workspace
        @root_id = root_id
        @now = now
        @session = session
        @resolver = resolver
        @feed = feed
        @clock = clock
        @start = clock.call if feed
      end

      def live?
        !@feed.nil?
      end

      # Release any events whose time has arrived into the graph (single-writer, on
      # request — the consumer drives the clock, exactly like Cascade#tick). Returns
      # whether anything new landed. A no-op for a static (non-live) App.
      def pump
        return false unless @feed

        @feed.release(@clock.call - @start, into: @workspace.graph)
      end

      # The log seq the client polls on — bumps as events are released.
      def version
        @feed ? @feed.log.version : 0
      end

      def done?
        @feed ? @feed.done? : true
      end

      # node id (+ optional tab/mode key) -> serializer Hash, or nil for an unknown
      # node. `mode` selects a tab; an unknown/absent key falls back to auto (head).
      def panel(node_id, mode: nil)
        node = @workspace.node(node_id)
        return nil unless node

        modes = @resolver.modes_for(node, session: @session)
        chosen = pick(modes, mode)
        view = chosen.panel(node, @workspace, now: @now)
        Serializer.panel(view, modes: modes.map(&:name))
      end

      # The cascade's starting point, as the client would fetch it.
      def root
        panel(@root_id)
      end

      private

      def pick(modes, key)
        return modes.first unless key

        modes.find { |mode| mode.name.to_s == key.to_s } || modes.first
      end
    end
  end
end
