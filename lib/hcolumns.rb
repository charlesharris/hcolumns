# frozen_string_literal: true

require_relative "hcolumns/version"
require_relative "hcolumns/identity"
require_relative "hcolumns/evidence"
require_relative "hcolumns/observation"
require_relative "hcolumns/node"
require_relative "hcolumns/edge"
require_relative "hcolumns/graph"
require_relative "hcolumns/event_log"
require_relative "hcolumns/persistence"
require_relative "hcolumns/flag_store"
require_relative "hcolumns/tail_reader"
require_relative "hcolumns/bridge_mount"
require_relative "hcolumns/log_producer"
require_relative "hcolumns/agent_bridge"
require_relative "hcolumns/llm_task_runner"
require_relative "hcolumns/strategies/tmux_claude_code"
require_relative "hcolumns/initializer"
require_relative "hcolumns/tuner"
require_relative "hcolumns/lens"
require_relative "hcolumns/lenses/reviewer_lens"
require_relative "hcolumns/lenses/explorer_lens"
require_relative "hcolumns/lenses/git_lens"
require_relative "hcolumns/lenses/filesystem_lens"
require_relative "hcolumns/lenses/beads_lens"
require_relative "hcolumns/lenses/session_lens"
require_relative "hcolumns/column"
require_relative "hcolumns/column_builder"
require_relative "hcolumns/workspace"
require_relative "hcolumns/searcher"
require_relative "hcolumns/cascade"
require_relative "hcolumns/providers/in_memory_fixture"
require_relative "hcolumns/providers/agent_session"
require_relative "hcolumns/providers/filesystem"
require_relative "hcolumns/providers/naming_rules"
require_relative "hcolumns/providers/git"
require_relative "hcolumns/providers/beads"
require_relative "hcolumns/providers/ruby_code"
require_relative "hcolumns/providers/transcript"
require_relative "hcolumns/providers/context_advice"
require_relative "hcolumns/renderers/text"
require_relative "hcolumns/renderers/detail"
require_relative "hcolumns/panel"
require_relative "hcolumns/mode"
require_relative "hcolumns/content_modes"
require_relative "hcolumns/context_modes"
require_relative "hcolumns/session_context"
require_relative "hcolumns/mode_resolver"
require_relative "hcolumns/renderers/cascade_text"
require_relative "hcolumns/web/app_source"
require_relative "hcolumns/web/serializer"
require_relative "hcolumns/web/app"
require_relative "hcolumns/web/server"
require_relative "hcolumns/tui"
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
