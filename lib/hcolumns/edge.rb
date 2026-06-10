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

    # Σ contributions, squashed into [0,1). More / fresher / stronger / more
    # varied evidence => higher confidence; old evidence decays out of the sum.
    def confidence(now:)
      sum = observations.sum { |o| o.contribution(now: now) }
      1.0 - Math.exp(-sum)
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

    # Derived discrete state used by the UI (and, later, crystallization).
    def maturity(now:)
      return :confirmed if human_confirmations.positive?

      c = confidence(now: now)
      return :reinforced if evidence_kinds.size >= 2 && c >= 0.5
      return :suggested if c >= 0.3

      :observed
    end
  end
end
