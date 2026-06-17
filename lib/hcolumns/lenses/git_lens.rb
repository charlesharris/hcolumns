# frozen_string_literal: true

module HColumns
  module Lenses
    # The git facet: lift commits, branches, authorship, and co-change to the top
    # and dim the filesystem/code families. They stay reachable, just lower —
    # fugitive-style "I'm in git headspace" without leaving the columns. Relation
    # emphasis does the lifting; history is also nudged up so older commits don't
    # decay out of sight.
    class GitLens < Lens
      def self.default_name = :git

      def self.default_tuner
        Tuner.new({ recency: 0.6 }, evidence_mix: { history: 1.3 })
      end

      def self.default_relation_weights
        {
          # git facet, lifted
          HEAD: 1.8, HAS_BRANCH: 1.6, POINTS_AT: 1.5, PARENT: 1.4,
          CHANGED: 1.4, CO_CHANGED_WITH: 1.5, CHANGED_BY: 1.5, AUTHORED_BY: 1.5,
          # files / code, dimmed (still present)
          CONTAINS: 0.3, DEFINES: 0.4, DEPENDS_ON: 0.5, REFERENCES: 0.4, PAIR: 0.5
        }
      end
    end

    Lens.register(GitLens)
  end
end
