# frozen_string_literal: true

module HColumns
  module Lenses
    # The structural mirror of the git lens: lift containment, definitions, and
    # source/test pairing — how the code is laid out — and dim the history/git
    # families. The lens for "show me the shape of the tree, not its churn."
    #
    # It exists as much to demonstrate the pattern as to be useful: a domain lens
    # is one small file that overrides config — no engine changes.
    class FilesystemLens < Lens
      def self.default_name = :filesystem

      def self.default_tuner
        Tuner.new(evidence_mix: { structure: 1.2 })
      end

      def self.default_relation_weights
        {
          # structure / code, lifted
          CONTAINS: 1.6, DEFINES: 1.5, PAIR: 1.4, DEPENDS_ON: 1.4, REFERENCES: 1.2,
          # history / git, dimmed
          CO_CHANGED_WITH: 0.4, CHANGED_BY: 0.3, CHANGED: 0.4, AUTHORED_BY: 0.3,
          HAS_BRANCH: 0.3, HEAD: 0.3, POINTS_AT: 0.3, PARENT: 0.3
        }
      end
    end

    Lens.register(FilesystemLens)
  end
end
