# frozen_string_literal: true

module HColumns
  # Find nodes by name/type without knowing where they live — the read
  # affordance `hcol json` can't offer (it needs an address to start from).
  # Graph-native by design: one breadth-first expansion over the composed
  # workspace reaches every stratum (fs, git, beads, ruby, the session), and a
  # future provider's nodes are searchable the day it lands, for free.
  #
  # The graph is lazy, so searching means materializing: expand outward from
  # the root until the frontier drains or the node cap trips. The cap is a
  # safety rail against unbounded strata (deep git history), and it is REPORTED
  # (`capped?`), never silent — a capped search says so instead of reading as
  # "searched everything".
  class Searcher
    NODE_CAP = 5_000

    attr_reader :workspace

    def initialize(workspace, now:, node_cap: NODE_CAP)
      @workspace = workspace
      @now = now
      @node_cap = node_cap
      @capped = false
    end

    def capped?
      @capped
    end

    # Case-insensitive substring match over a node's name and path, optionally
    # narrowed to a node type. Returns nodes sorted by type then name.
    def find(term, from:, type: nil)
      expand_all(from)
      needle = term.to_s.downcase
      wanted = type&.downcase
      @workspace.graph.nodes
                .select { |n| (wanted.nil? || n.type.to_s.downcase == wanted) && haystack(n).include?(needle) }
                .sort_by { |n| [n.type.to_s, n.name.to_s.downcase] }
    end

    # Materialize the reachable graph: breadth-first from `from`, expanding
    # each node once (the Workspace memoizes), collecting edge targets as the
    # next ring. Public so an id lookup can reuse the same reach — anything a
    # search can find, `hcol json obj:<id>` can address.
    def expand_all(from)
      frontier = [from]
      seen = { from => true }
      until frontier.empty?
        if seen.size > @node_cap
          @capped = true
          break
        end
        node_id = frontier.shift
        @workspace.expand(node_id, now: @now)
        @workspace.graph.edges_from(node_id).each do |edge|
          next if seen[edge.target_id]

          seen[edge.target_id] = true
          frontier << edge.target_id
        end
      end
      self
    end

    private

    def haystack(node)
      "#{node.name} #{node.properties[:path]}".downcase
    end
  end
end
