# frozen_string_literal: true

module HColumns
  # Turns a node + the graph + the lens into a Column: take the node's outgoing
  # edges, drop what the lens scopes out or scores below its floor, score the
  # rest, group by relation type, and apply a total order so output is
  # deterministic (score desc, ties broken by id). This is the heart of the
  # "structured + directed" rendering of the graph.
  class ColumnBuilder
    def initialize(graph, lens: Lens.new(name: :default))
      @graph = graph
      @lens = lens
    end

    def build(node_id, now:)
      root = @graph.node(node_id)
      raise ArgumentError, "no such node: #{node_id}" unless root

      entries = @graph.edges_from(node_id).filter_map do |edge|
        target = @graph.node(edge.target_id)
        next unless target
        next unless @lens.admits?(edge.type)        # scope: hide whole families
        next unless @lens.visible?(edge, now: now)  # floor: hide weak edges

        ColumnEntry.new(edge: edge, target: target, now: now, lens: @lens)
      end

      groups = entries
               .group_by(&:relation)
               .map { |relation, es| ColumnGroup.new(relation: relation, entries: sort_entries(es)) }
               .sort_by { |g| [-g.top_score, g.relation.to_s] }

      Column.new(root: root, groups: groups)
    end

    private

    # Total order within a group: score desc, then name (case-insensitive) so
    # structural siblings read alphabetically, then id as a final determinism key.
    def sort_entries(entries)
      entries.sort_by { |e| [-e.score, e.target.name.to_s.downcase, e.target.id] }
    end
  end
end
