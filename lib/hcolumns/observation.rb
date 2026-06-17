# frozen_string_literal: true

module HColumns
  # The real primitive. Providers never write edges directly; they append
  # observations asserting that, on the basis of some evidence, two objects are
  # related. An edge is the fold of all observations sharing (subject, object, type).
  class Observation
    attr_reader :provider, :subject_id, :target_id, :edge_type,
                :weight, :evidence_kind, :evidence_summary, :observed_at

    def initialize(provider:, subject_id:, target_id:, edge_type:, observed_at:,
                   weight: 1.0, evidence_kind: :inference, evidence_summary: nil)
      @provider = provider
      @subject_id = subject_id
      @target_id = target_id
      @edge_type = edge_type.to_sym
      @weight = weight
      @evidence_kind = evidence_kind.to_sym
      @evidence_summary = evidence_summary
      @observed_at = observed_at
      Evidence.kind(@evidence_kind) # validate eagerly
    end

    def key
      [subject_id, target_id, edge_type]
    end

    # A single occurrence of this observation never asserts absolute certainty,
    # so confidence stays in [0,1) however strong one signal is.
    MAX_RELIABILITY = 0.999

    def decay(now:)
      Evidence.decay(kind: evidence_kind, observed_at: observed_at, now: now)
    end

    # This observation's reliability — how much it moves the edge's confidence
    # under the noisy-OR fold; `weight` counts occurrences (the exponent).
    #
    # Deterministic evidence is verifiable ground truth: it returns 1.0 flat (no
    # decay, no lens mix — you can't be more or less than certain of a fact), so a
    # single such observation pins the edge to full confidence. Probabilistic
    # evidence is per-occurrence certainty in (0,1), aged by decay, re-weighted by
    # the lens's evidence-mix, and capped below 1 so it never asserts certainty.
    def reliability(now:, mix: nil)
      return 1.0 if Evidence.deterministic?(evidence_kind)

      r = Evidence.reliability(evidence_kind) * decay(now: now)
      r *= mix.fetch(evidence_kind, 1.0) if mix
      r.clamp(0.0, MAX_RELIABILITY)
    end
  end
end
