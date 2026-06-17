# frozen_string_literal: true

module HColumns
  module Providers
    # A hand-authored *agent session* — the guiding-star substrate.
    #
    # An LLM coding agent's work produces a **route** —
    #
    #   Task → ProposedChange → the files it touches → a TestRun → a LogLine
    #
    # which we claim is intrinsically a column-walk (vs. a dashboard's flattened
    # overview). The session is defined once as an ordered `script` of events on a
    # timeline (`after:` seconds from the start). Two ways to consume it:
    #
    #   * `build(now:)`  — fold the whole script at once → a frozen Graph
    #     (`hcol explore/walk session`). The route, already grown.
    #   * `Feed`         — release events as their `after` time arrives, appending
    #     to an EventLog and folding into a graph as they land. Drives the *live*
    #     walk (`hcol walk session --live`): the column grows as the agent "works",
    #     which is the guiding star — the session reflected in the UI as it happens.
    #
    # Two evidence modes show up deliberately: the diff *really* touches these files
    # / the agent *really* ran the tests → `structure`, confidence 1.0; "this change
    # addresses the task", "this file is the focus" are the agent's *assertions* →
    # the `agent` kind (0.7, ages ~7d). Touched files carry real `fs.path` ids, so
    # in a live workspace they unify with the filesystem/git/ruby nodes.
    module AgentSession
      module_function

      SESSION_KEY = { scheme: "agent.session", key: "s1" }.freeze

      def session_id
        Identity.id_for(**SESSION_KEY)
      end

      # The session as an ordered list of timed events: each is
      # { after: seconds_from_start, kind: :node | :observe, payload: ... }.
      def script(now:)
        node = lambda do |type, identity, name|
          Node.new(type: type, identity: identity, properties: { name: name, path: name })
        end
        file = ->(path) { node.(:SourceFile, { scheme: "fs.path", key: "local:/repo/#{path}" }, path) }

        session = node.(:Session, SESSION_KEY, "Task: add agent provider")
        agent   = node.(:Agent, { scheme: "agent", key: "claude" }, "claude")
        change  = node.(:ProposedChange, { scheme: "agent.change", key: "s1:c1" },
                        "diff: agent_session provider (+evidence kind)")

        provider_rb = file.("lib/hcolumns/providers/agent_session.rb")
        evidence_rb = file.("lib/hcolumns/evidence.rb")
        requires_rb = file.("lib/hcolumns.rb")
        spec_rb     = file.("spec/providers/agent_session_spec.rb")

        test = node.(:TestRun, { scheme: "agent.test", key: "s1:t1" }, "rspec — 84 examples")
        log  = node.(:LogLine, { scheme: "agent.log", key: "s1:l1" }, "0 failures (0.9s)")

        # The agent is acting *now*, so observations are fresh; `after` is the live
        # release timeline (seconds), distinct from the observation's logical time.
        obs = lambda do |subject, object, type, kind, summary, weight: 1.0|
          { kind: :observe,
            payload: Observation.new(provider: :agent, subject_id: subject.id, target_id: object.id,
                                     edge_type: type, weight: weight, evidence_kind: kind,
                                     observed_at: now, evidence_summary: summary) }
        end
        add = ->(n) { { kind: :node, payload: n } }

        entries = [
          # t0 — the task exists and we know who is driving it
          [0.0, add.(session)],
          [0.0, add.(agent)],
          [0.0, obs.(session, agent, :DRIVEN_BY, :structure, "session actor")],
          # ~1s — the agent proposes a change for the task (its assertion, ages)
          [1.0, add.(change)],
          [1.0, obs.(session, change, :PROPOSES, :agent, "proposed to satisfy the task")],
          # the diff lands file by file — verifiable ground truth (1.0 each)
          [1.6, add.(provider_rb)],
          [1.6, obs.(change, provider_rb, :TOUCHES, :structure, "diff hunk (+221)")],
          [1.6, obs.(change, provider_rb, :FOCUSES_ON, :agent, "primary file (221 of 260 lines)")],
          [2.1, add.(evidence_rb)],
          [2.1, obs.(change, evidence_rb, :TOUCHES, :structure, "diff hunk (+1)")],
          [2.6, add.(requires_rb)],
          [2.6, obs.(change, requires_rb, :TOUCHES, :structure, "diff hunk (+1)")],
          [3.1, add.(spec_rb)],
          [3.1, obs.(change, spec_rb, :TOUCHES, :structure, "diff hunk (+38)")],
          # ~4s — the agent runs the suite to verify, which emits a summary line
          [4.0, add.(test)],
          [4.0, obs.(change, test, :VERIFIED_BY, :behavior, "ran rspec after the edit")],
          [4.6, add.(log)],
          [4.6, obs.(test, log, :EMITTED, :behavior, "rspec summary line")]
        ]

        entries.map { |after, e| e.merge(after: after) }
      end

      # The frozen graph: release the whole script at once (timeline collapsed).
      def build(now:)
        graph = Graph.new
        feed(now: now).release(Float::INFINITY, into: graph)
        graph
      end

      def feed(now:, log: EventLog.new)
        Feed.new(script(now: now), log: log)
      end

      # Releases a timed script into an EventLog as wall-clock elapses, folding the
      # newly-released tail into a projection graph. Duck-typed for Cascade#tick:
      # `release(elapsed, into:) -> Boolean` (did anything land?). Single-writer —
      # the consumer polls and drives it, so there is no cross-thread mutation.
      class Feed
        attr_reader :log

        def initialize(script, log: EventLog.new)
          @script = script
          @log = log
          @cursor = 0
        end

        # Append every entry whose `after` has arrived, fold the new tail into the
        # graph, and report whether the projection changed.
        def release(elapsed, into:)
          before = @log.version
          while @cursor < @script.length && @script[@cursor][:after] <= elapsed
            e = @script[@cursor]
            at = e[:payload].respond_to?(:observed_at) ? e[:payload].observed_at : nil
            @log.append(kind: e[:kind], at: at, payload: e[:payload])
            @cursor += 1
          end
          newly = @log.since(before)
          @log.fold(newly, into: into)
          !newly.empty?
        end

        def done?
          @cursor >= @script.length
        end
      end
    end
  end
end
