# frozen_string_literal: true

module HColumns
  # The fixed set of evidence kinds, in two modes:
  #
  #   deterministic — verifiable ground truth. The relation is read straight off a
  #     source (the filesystem really contains the file; the AST really defines the
  #     class), so its confidence is exactly 1.0 — re-checking would only re-confirm
  #     it. It does not decay or accrue, and a lens cannot dim its *confidence*
  #     (only its ranking, via relation weights). Decaying even these over time is a
  #     possible future knob; for now, a fact is a fact.
  #
  #   probabilistic — evidence that something is *likely* true, never certain from
  #     one look. `reliability` is the per-occurrence certainty in (0,1): how much a
  #     single observation moves confidence under the noisy-OR fold (Edge#confidence).
  #     More/stronger observations accrue; old ones decay (`half_life_days`, nil =
  #     no decay). A naming-convention guess sits well above a doc mention but well
  #     below containment.
  module Evidence
    KINDS = {
      structure:  { deterministic: true,  reliability: 1.0,  half_life_days: nil },  # containment, AST defs, resolved requires
      human:      { deterministic: false, reliability: 0.95, half_life_days: nil },  # a person's judgement — does not decay
      convention: { deterministic: false, reliability: 0.55, half_life_days: nil },  # follows a naming/layout convention (heuristic)
      behavior:   { deterministic: false, reliability: 0.6,  half_life_days: 14.0 }, # runtime/telemetry signal — ages fast
      history:    { deterministic: false, reliability: 0.5,  half_life_days: 90.0 }, # git co-change, authorship — accrues
      inference:  { deterministic: false, reliability: 0.3,  half_life_days: 30.0 }  # a guess (e.g. an LLM)
    }.freeze

    DAY_SECONDS = 86_400.0

    def self.kind(name)
      KINDS.fetch(name) { raise ArgumentError, "unknown evidence_kind: #{name.inspect}" }
    end

    def self.deterministic?(name)
      kind(name).fetch(:deterministic, false)
    end

    def self.reliability(name)
      kind(name).fetch(:reliability)
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
