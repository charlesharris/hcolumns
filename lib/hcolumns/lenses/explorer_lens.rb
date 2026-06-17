# frozen_string_literal: true

module HColumns
  module Lenses
    # Low floor + history/inference-friendly: surface speculative and historical
    # leads and weight freshness up. The lens for poking around — show me the
    # hunches, not just the certainties.
    class ExplorerLens < Lens
      def self.default_name = :explorer

      def self.default_tuner
        Tuner.new({ floor: 0.0, recency: 0.6 },
                  evidence_mix: { history: 1.4, inference: 1.6, behavior: 1.2 })
      end
    end

    Lens.register(ExplorerLens)
  end
end
