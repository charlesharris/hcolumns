# frozen_string_literal: true

module HColumns
  module Lenses
    # The agent-session facet: read the columns as "what is the agent doing",
    # not "what is the code". Lift the session stratum — the mount seam, the
    # session's route (driver, change-set, verification, log) — and dim the
    # filesystem/git/plan families so a walk stays in session headspace. The
    # return seam (IN_PROJECT) stays near par: the way back out is part of the
    # view. Recency matters more here than anywhere — a live session's newest
    # events are the point — and agent-kind evidence is trusted a little more.
    class SessionLens < Lens
      def self.default_name = :session

      def self.default_tuner
        Tuner.new({ recency: 0.8 }, evidence_mix: { agent: 1.3 })
      end

      def self.default_relation_weights
        {
          # the session stratum, lifted
          HAS_SESSION: 1.9, DRIVEN_BY: 1.5, PROPOSES: 1.7, FOCUSES_ON: 1.5,
          TOUCHES: 1.5, VERIFIED_BY: 1.7, EMITTED: 1.4, IN_PROJECT: 1.1,
          # filesystem / git / plan, dimmed (still reachable)
          CONTAINS: 0.3, DEFINES: 0.4, DEPENDS_ON: 0.4, REFERENCES: 0.3, PAIR: 0.4,
          HAS_BRANCH: 0.3, HEAD: 0.3, POINTS_AT: 0.3, PARENT: 0.3,
          CO_CHANGED_WITH: 0.4, CHANGED_BY: 0.4, AUTHORED_BY: 0.3,
          HAS_BEADS: 0.4, HAS_BEAD: 0.4, HAS_READY: 0.4, HAS_BLOCKED: 0.4
        }
      end
    end

    Lens.register(SessionLens)
  end
end
