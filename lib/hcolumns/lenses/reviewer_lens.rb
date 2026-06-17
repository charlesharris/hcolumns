# frozen_string_literal: true

module HColumns
  module Lenses
    # Strict + structure/human: trust deterministic facts and human calls,
    # discount history/inference, and hide weak edges below the floor. The lens
    # for reviewing — only the things you can stand behind.
    class ReviewerLens < Lens
      def self.default_name = :reviewer

      def self.default_tuner
        Tuner.new({ floor: 0.35 },
                  evidence_mix: { structure: 1.4, human: 1.6, behavior: 0.8,
                                  history: 0.6, inference: 0.3 })
      end
    end

    Lens.register(ReviewerLens)
  end
end
