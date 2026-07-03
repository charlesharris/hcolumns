# frozen_string_literal: true

module HColumns
  # The property-graph read-model the columns consume: nodes keyed by id, and a
  # derived edge projection keyed by (subject, object, type). Providers feed it by
  # appending observations; the graph folds each into its edge. For layer one this
  # *is* the source of truth (mutable graph + provenance on edges); an event log
  # can slot in underneath later without changing this read interface.
  class Graph
    # An optional EventLog makes this graph log-backed: mutations are recorded as
    # events (source of truth) *and* applied to the projection. With no log it's a
    # plain mutable graph (layer one) — and a projection folded *from* a log is
    # itself log-less (its log is upstream), so folding uses the apply_* path,
    # which records nothing.
    # The vocabulary of human node flags: ranking opinion, folded beside (never
    # into) the evidence. :clear removes a flag (last-flag-wins is the undo).
    FLAG_LEVELS = %i[up down exclude clear].freeze

    def initialize(log: nil)
      @nodes = {}
      @edges = {}
      @flags = {}
      @log = log
    end

    def add_node(node)
      @log&.append(kind: :node, payload: node)
      apply_node(node)
    end

    # Apply a node to the projection without recording it (the replay path).
    def apply_node(node)
      @nodes[node.id] = node
      node
    end

    def node(id)
      @nodes[id]
    end

    def nodes
      @nodes.values
    end

    # Record + fold an observation. The fold itself is apply_observe.
    def observe(observation)
      @log&.append(kind: :observe, at: observation.observed_at, payload: observation)
      apply_observe(observation)
    end

    # Fold an observation into the derived edge projection (no recording).
    def apply_observe(observation)
      edge = (@edges[observation.key] ||= Edge.new(
        subject_id: observation.subject_id,
        target_id: observation.target_id,
        type: observation.edge_type
      ))
      edge.add(observation)
      self
    end

    # Record + fold a human flag on a node. This is opinion, not evidence: it
    # never touches an edge or its confidence — lenses read it as a score bias
    # (see Lens#bias), so the inspector keeps showing the untouched truth.
    def flag(node_id:, level:, by: nil, at: nil)
      raise ArgumentError, "unknown flag level: #{level.inspect}" unless FLAG_LEVELS.include?(level)

      payload = { node_id: node_id, level: level, by: by, at: at }
      @log&.append(kind: :flag, at: at, payload: payload)
      apply_flag(payload)
      payload
    end

    # Fold a flag into the projection without recording (the replay path).
    # Last flag wins; :clear deletes.
    def apply_flag(payload)
      if payload[:level] == :clear
        @flags.delete(payload[:node_id])
      else
        @flags[payload[:node_id]] = payload
      end
      self
    end

    def flag_of(node_id)
      @flags[node_id]&.fetch(:level)
    end

    def flag_info(node_id)
      @flags[node_id]
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
