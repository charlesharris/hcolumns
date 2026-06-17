# frozen_string_literal: true

module HColumns
  # A derived relationship: the fold of all observations sharing
  # (subject, object, type). Confidence and maturity are pure functions of the
  # contributing observations and `now` — never stored as truth, always
  # recomputable. The observations themselves are the provenance.
  class Edge
    attr_reader :subject_id, :target_id, :type, :observations

    def initialize(subject_id:, target_id:, type:)
      @subject_id = subject_id
      @target_id = target_id
      @type = type.to_sym
      @observations = []
    end

    def add(observation)
      @observations << observation
      self
    end

    def key
      [subject_id, target_id, type]
    end

    # Noisy-OR over the observations: each is independent evidence that the
    # relation holds, so confidence is the chance that *at least one* is right —
    # 1 − ∏(1 − reliabilityᵢ). It rises with more / stronger evidence and falls as
    # evidence decays. Deterministic kinds (structure) are near-certain from a
    # single observation; uncertain kinds (history, inference) accrue. An
    # observation's `weight` counts repeated occurrences (the exponent).
    #
    # `mix` is the lens's per-evidence-kind re-weighting — a *view* of the fold,
    # never mutating it. nil (or a missing kind) means no change.
    def confidence(now:, mix: nil)
      survival = observations.reduce(1.0) do |acc, o|
        acc * ((1.0 - o.reliability(now: now, mix: mix))**o.weight)
      end
      1.0 - survival
    end

    # Freshness of the relationship: its least-decayed (strongest-now) observation.
    def recency(now:)
      return 0.0 if observations.empty?

      observations.map { |o| o.decay(now: now) }.max
    end

    def evidence_kinds
      observations.map(&:evidence_kind).uniq
    end

    def human_confirmations
      observations.count { |o| o.evidence_kind == :human }
    end

    # True if any observation is verifiable ground truth (a deterministic kind) —
    # the relation is a fact read off a source, not inferred.
    def deterministic?
      observations.any? { |o| Evidence.deterministic?(o.evidence_kind) }
    end

    # Derived discrete state used by the UI (and, later, crystallization). Ground
    # truth (deterministic) or a human's sign-off both count as confirmed; weaker
    # evidence is reinforced (corroborated across kinds), then suggested/observed.
    def maturity(now:)
      return :confirmed if deterministic? || human_confirmations.positive?

      c = confidence(now: now)
      return :reinforced if evidence_kinds.size >= 2 && c >= 0.5
      return :suggested if c >= 0.3

      :observed
    end
  end
end
