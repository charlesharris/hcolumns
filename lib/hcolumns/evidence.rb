# frozen_string_literal: true

module HColumns
  # The fixed set of evidence kinds and how they age. A relation backed by a
  # runtime trace decays faster than a static source/test pairing; a human
  # judgement does not decay at all. `weight` is the type-weight folded into an
  # edge's confidence; `half_life_days` drives exponential decay (nil = no decay).
  module Evidence
    KINDS = {
      structure: { weight: 1.0, half_life_days: nil },  # deterministic facts (containment, naming pairs)
      behavior:  { weight: 0.8, half_life_days: 14.0 },  # runtime/telemetry signal — ages fast
      history:   { weight: 0.7, half_life_days: 90.0 },  # git co-change, authorship
      human:     { weight: 1.5, half_life_days: nil },   # a person's judgement — does not decay
      inference: { weight: 0.4, half_life_days: 30.0 }   # a guess (e.g. an LLM/heuristic)
    }.freeze

    DAY_SECONDS = 86_400.0

    def self.kind(name)
      KINDS.fetch(name) { raise ArgumentError, "unknown evidence_kind: #{name.inspect}" }
    end

    def self.weight(name)
      kind(name)[:weight]
    end

    # Exponential decay in (0,1] for an observation of `name` made at `observed_at`,
    # evaluated at `now`. Both are Time. nil half-life => no decay. Future-dated
    # observations are treated as fully fresh.
    def self.decay(kind:, observed_at:, now:)
      half_life = kind(kind)[:half_life_days]
      return 1.0 if half_life.nil?

      age_days = (now - observed_at) / DAY_SECONDS
      age_days = 0.0 if age_days.negative?
      0.5**(age_days / half_life)
    end
  end
end
