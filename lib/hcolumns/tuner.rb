# frozen_string_literal: true

module HColumns
  # The ranking function for a column. A knob re-weights a term; it does not
  # toggle data on/off, so the same graph yields different surfaces with no
  # recompute. Two scoring terms (confidence, recency), plus two lens knobs:
  #
  #   floor         a visibility threshold on (mix-adjusted) confidence — weak
  #                 edges drop below it. Strict ↔ speculative. Default 0.0 hides
  #                 nothing, so the default tuner is identical to layer one.
  #   evidence_mix  per-evidence-kind multipliers folded into confidence (trust
  #                 structure/human vs. surface history/inference). Empty = neutral.
  #
  # Scoping (hiding whole relation families) is deliberately *not* here — that
  # would toggle data; it lives one layer up, in Lens. The tuner only re-weights.
  class Tuner
    DEFAULTS = { confidence: 1.0, recency: 0.3, floor: 0.0 }.freeze

    attr_reader :weights, :evidence_mix

    def initialize(weights = {}, evidence_mix: {})
      @weights = DEFAULTS.merge(weights)
      @evidence_mix = evidence_mix
    end

    def score(edge, now:)
      weights[:confidence] * confidence(edge, now: now) +
        weights[:recency] * edge.recency(now: now)
    end

    # The lens-adjusted confidence (evidence-mix applied). This is what the floor
    # tests and what the UI displays, so the surfaced number is honest about the
    # active mix rather than silently scoring on one value and showing another.
    def confidence(edge, now:)
      edge.confidence(now: now, mix: evidence_mix)
    end

    def floor
      weights[:floor]
    end

    # Below the floor, an edge is hidden from the column (re-weighting, not a
    # data change: lower the floor and it returns).
    def visible?(edge, now:)
      confidence(edge, now: now) >= floor
    end
  end
end
