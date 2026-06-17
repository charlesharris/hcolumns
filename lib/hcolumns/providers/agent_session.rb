# frozen_string_literal: true

module HColumns
  module Providers
    # A hand-authored *agent session* graph — the guiding-star substrate, frozen.
    #
    # This is the thesis the whole hügel line deferred, made concrete enough to
    # look at: an LLM coding agent's work produces a **route** —
    #
    #   Task → ProposedChange → the files it touches → a TestRun → a LogLine
    #
    # which we claim is intrinsically a column-walk (vs. a dashboard's flattened
    # overview). This builder freezes one such session into the same property
    # graph everything else uses, so `hcol explore session` / `hcol walk session`
    # render it through the unchanged pipeline. No event log, no live push yet —
    # that's the next fork; this is the cheapest test of whether the walk is good.
    #
    # Two evidence modes show up deliberately:
    #   * the diff *really* touches these files, the agent *really* ran the tests —
    #     verifiable ground truth → `structure`, confidence 1.0;
    #   * "this change addresses the task", "this file is the focus" — the agent's
    #     deliberate *assertion* → the `agent` kind (0.7, ages over ~7d as the
    #     session moves on), above a blind inference, below a human confirmation.
    #
    # The touched files carry real `fs.path` identities, so in a live workspace
    # (with the filesystem/git/ruby providers attached) they are the *same* nodes
    # those providers expand — the session weaves into the code graph, not beside it.
    module AgentSession
      module_function

      SESSION_KEY = { scheme: "agent.session", key: "s1" }.freeze

      def session_id
        Identity.id_for(**SESSION_KEY)
      end

      def build(now:)
        graph = Graph.new
        days = ->(d) { now - (d * Evidence::DAY_SECONDS) }

        add = ->(node) { graph.add_node(node) }
        file = lambda do |path|
          add.(Node.new(type: :SourceFile, identity: { scheme: "fs.path", key: "local:/repo/#{path}" },
                        properties: { name: path, path: path }))
        end

        session = add.(Node.new(type: :Session, identity: SESSION_KEY,
                                properties: { name: "Task: add agent provider" }))
        agent   = add.(Node.new(type: :Agent, identity: { scheme: "agent", key: "claude" },
                                properties: { name: "claude" }))
        change  = add.(Node.new(type: :ProposedChange, identity: { scheme: "agent.change", key: "s1:c1" },
                                properties: { name: "diff: agent_session provider (+evidence kind)" }))

        provider_rb = file.("lib/hcolumns/providers/agent_session.rb")
        evidence_rb = file.("lib/hcolumns/evidence.rb")
        requires_rb = file.("lib/hcolumns.rb")
        spec_rb     = file.("spec/providers/agent_session_spec.rb")

        test = add.(Node.new(type: :TestRun, identity: { scheme: "agent.test", key: "s1:t1" },
                             properties: { name: "rspec — 80 examples" }))
        log  = add.(Node.new(type: :LogLine, identity: { scheme: "agent.log", key: "s1:l1" },
                             properties: { name: "0 failures (0.9s)" }))

        obs = lambda do |provider, subject, object, type, **kw|
          graph.observe(Observation.new(provider: provider, subject_id: subject.id,
                                        target_id: object.id, edge_type: type, **kw))
        end

        # who is driving the session — a fact about the session
        obs.(:agent, session, agent, :DRIVEN_BY, weight: 1.0, evidence_kind: :structure,
             observed_at: days.(0), evidence_summary: "session actor")

        # the agent's assertion: this change is the work for this task (ages)
        obs.(:agent, session, change, :PROPOSES, weight: 1.0, evidence_kind: :agent,
             observed_at: days.(0), evidence_summary: "proposed to satisfy the task")

        # the diff verifiably touches these files (ground truth, parsed from the diff)
        [[provider_rb, "+218"], [evidence_rb, "+1"], [requires_rb, "+1"], [spec_rb, "+34"]].each do |f, churn|
          obs.(:agent, change, f, :TOUCHES, weight: 1.0, evidence_kind: :structure,
               observed_at: days.(0), evidence_summary: "diff hunk (#{churn})")
        end

        # the new file is the focus of the change — the agent's emphasis, not a fact
        obs.(:agent, change, provider_rb, :FOCUSES_ON, weight: 1.0, evidence_kind: :agent,
             observed_at: days.(0), evidence_summary: "primary file (218 of 254 lines)")

        # the agent ran the suite to verify the change; the run emitted a log line
        obs.(:agent, change, test, :VERIFIED_BY, weight: 1.0, evidence_kind: :behavior,
             observed_at: days.(0), evidence_summary: "ran rspec after the edit")
        obs.(:agent, test, log, :EMITTED, weight: 1.0, evidence_kind: :behavior,
             observed_at: days.(0), evidence_summary: "rspec summary line")

        graph
      end
    end
  end
end
