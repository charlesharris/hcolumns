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

    def decay(now:)
      Evidence.decay(kind: evidence_kind, observed_at: observed_at, now: now)
    end

    # This observation's decay-weighted, type-weighted contribution to confidence.
    def contribution(now:)
      decay(now: now) * Evidence.weight(evidence_kind) * weight
    end
  end
end
