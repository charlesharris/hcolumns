# frozen_string_literal: true

require_relative "hcolumns/version"
require_relative "hcolumns/identity"
require_relative "hcolumns/evidence"
require_relative "hcolumns/observation"
require_relative "hcolumns/node"
require_relative "hcolumns/edge"
require_relative "hcolumns/graph"
require_relative "hcolumns/tuner"
require_relative "hcolumns/column"
require_relative "hcolumns/column_builder"
require_relative "hcolumns/providers/in_memory_fixture"
require_relative "hcolumns/renderers/text"
require_relative "hcolumns/cli"

# HColumns — semantically-directed Miller columns ("Harris Columns").
#
# A structured, directed way to explore a property graph: the same data a
# Neo4j-style browser holds (nodes + typed/weighted edges + properties), rendered
# as ranked, relation-grouped, walkable columns instead of a freeform canvas.
#
# Pipeline: providers append Observations -> Graph folds them into Edges (with
# derived confidence/maturity) -> Tuner scores -> ColumnBuilder groups & ranks ->
# a Renderer displays the column. See docs/DESIGN.md.
module HColumns
end
