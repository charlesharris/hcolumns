# frozen_string_literal: true

module HColumns
  # The ranking function for a column. A knob re-weights a term; it does not
  # toggle data on/off, so the same graph yields different surfaces with no
  # recompute. Layer one ships two terms (confidence, recency); proximity,
  # novelty and fragility are reserved for later layers.
  class Tuner
    DEFAULTS = { confidence: 1.0, recency: 0.3 }.freeze

    attr_reader :weights

    def initialize(weights = {})
      @weights = DEFAULTS.merge(weights)
    end

    def score(edge, now:)
      weights[:confidence] * edge.confidence(now: now) +
        weights[:recency] * edge.recency(now: now)
    end
  end
end
