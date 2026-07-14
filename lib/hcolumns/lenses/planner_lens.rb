# frozen_string_literal: true

module HColumns
  module Lenses
    # The plan facet: read the columns as a plan, not a code graph. Lift the beads
    # relations — the index, the dependency web (parent/child, blocks), and the
    # file links in both directions — and dim the filesystem/code/history families
    # so a walk stays in "planning headspace". TOUCHED_BY is lifted highest so that
    # standing on a source file, the beads that touch it surface first. The agent's
    # metadata word is trusted a little more than a path scraped from prose.
    class PlannerLens < Lens
      def self.default_name = :planner

      def self.default_tuner
        Tuner.new({ recency: 0.4 }, evidence_mix: { agent: 1.2, inference: 0.7 })
      end

      def self.default_relation_weights
        {
          # the plan, lifted
          HAS_BEADS: 1.8, HAS_BEAD: 1.6,
          HAS_CHILD: 1.6, CHILD_OF: 1.5, BLOCKS: 1.7, BLOCKED_BY: 1.7,
          RELATED: 1.3, DISCOVERED_FROM: 1.2, TOUCHES: 1.4, TOUCHED_BY: 1.8,
          # code / filesystem / history, dimmed (still reachable)
          CONTAINS: 0.3, DEFINES: 0.4, DEPENDS_ON: 0.4, REFERENCES: 0.3,
          CO_CHANGED_WITH: 0.4, CHANGED_BY: 0.4, PAIR: 0.4
        }
      end
    end

    Lens.register(PlannerLens)
  end
end
