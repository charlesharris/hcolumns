# frozen_string_literal: true

module HColumns
  # The property-graph read-model the columns consume: nodes keyed by id, and a
  # derived edge projection keyed by (subject, object, type). Providers feed it by
  # appending observations; the graph folds each into its edge. For layer one this
  # *is* the source of truth (mutable graph + provenance on edges); an event log
  # can slot in underneath later without changing this read interface.
  class Graph
    def initialize
      @nodes = {}
      @edges = {}
    end

    def add_node(node)
      @nodes[node.id] = node
      node
    end

    def node(id)
      @nodes[id]
    end

    def nodes
      @nodes.values
    end

    # Fold an observation into the derived edge projection.
    def observe(observation)
      edge = (@edges[observation.key] ||= Edge.new(
        subject_id: observation.subject_id,
        target_id: observation.target_id,
        type: observation.edge_type
      ))
      edge.add(observation)
      self
    end

    def edges
      @edges.values
    end

    # Relations pointing *out* from a node — the candidates for its column.
    def edges_from(subject_id)
      @edges.values.select { |e| e.subject_id == subject_id }
    end

    def edges_into(target_id)
      @edges.values.select { |e| e.target_id == target_id }
    end
  end
end
