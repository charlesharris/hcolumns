# frozen_string_literal: true

module HColumns
  # Owns a graph and a set of on-demand providers, expanding nodes lazily: a
  # node's neighbors are loaded (providers consulted) only when its column is
  # first requested. This is the pull / on-demand seam — navigating into, or even
  # previewing, a node is what pulls its relations into the graph.
  #
  # A provider is any object responding to:
  #   recognizes?(node)         -> Boolean
  #   expand(node, graph, now:) -> appends nodes + observations for node's neighbors
  #
  # With no providers a Workspace just serves a pre-folded graph (the in-memory
  # fixture demo), so one API covers both eager and lazy sources.
  class Workspace
    attr_reader :graph, :lens

    def initialize(graph: Graph.new, providers: [], lens: Lens.new(name: :default))
      @graph = graph
      @providers = providers
      @expanded = {}
      self.lens = lens
    end

    # Swap the lens (the live retune). Only the read-model rebuilds — the graph
    # and what's already been expanded are untouched, so re-lensing is cheap.
    def lens=(new_lens)
      @lens = new_lens
      @builder = ColumnBuilder.new(@graph, lens: new_lens)
    end

    def add_node(node)
      @graph.add_node(node)
    end

    def node(id)
      @graph.node(id)
    end

    # Lazily expand the node (once), then build its ranked column.
    def column_for(node_id, now:)
      expand(node_id, now: now)
      @builder.build(node_id, now: now)
    end

    # Consult every provider that recognizes the node — exactly once per node, so
    # repeated visits don't re-append observations and inflate confidence.
    def expand(node_id, now:)
      return if @expanded[node_id]

      node = @graph.node(node_id)
      return unless node

      @expanded[node_id] = true
      @providers.each { |provider| provider.expand(node, @graph, now: now) if provider.recognizes?(node) }
    end
  end
end
