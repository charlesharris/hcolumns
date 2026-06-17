# frozen_string_literal: true

module HColumns
  # The session a walk is situated in — the seam the ModeResolver reads to bias
  # modes by what the agent is *doing*, not just where you are. The current phase
  # (exploring/editing/testing/debugging/reviewing) lives as a `:phase` property on
  # the Session node, so the agent declaring "I'm now debugging" is just another
  # event (re-emitting the node), it survives replay, and it shows in the inspector.
  #
  # Duck-typed for the resolver: anything answering `phase` works (a test can pass
  # a Struct). nil phase = no biasing (the plain by-type tabs).
  class SessionContext
    def initialize(graph:, node_id:)
      @graph = graph
      @node_id = node_id
    end

    def phase
      node = @graph.node(@node_id)
      node && node.properties[:phase]
    end
  end
end
