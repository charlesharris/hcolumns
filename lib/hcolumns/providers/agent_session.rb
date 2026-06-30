# frozen_string_literal: true

module HColumns
  module Providers
    # Hand-authored *agent sessions* — the guiding-star substrate.
    #
    # An LLM coding agent's work produces a **route** —
    #
    #   Task → ProposedChange → the files it touches → a TestRun → a LogLine
    #
    # which we claim is intrinsically a column-walk. Each session is described by a
    # small spec (SESSIONS); `session_events` turns one into an ordered, timed list
    # of events (nodes + observations on a `after:` timeline). Those events are
    # consumed three ways:
    #
    #   * `build(now:)`         — fold the live session whole → a frozen Graph
    #                             (`hcol explore/walk session`).
    #   * `Feed`                — release events as their time arrives → the live
    #                             walk grows under you (`hcol walk session --live`).
    #   * `sessions_graph(now:)`— an index node listing every session, each
    #                             descendable into its route (`hcol walk sessions`).
    #                             Pass `live_key:` to leave one session a shell whose
    #                             route a Feed streams (`hcol walk sessions --live`).
    #
    # Two evidence modes show up deliberately: the diff *really* touches these files
    # / the agent *really* ran the tests → `structure`, confidence 1.0; "this change
    # addresses the task" / "this file is the focus" are the agent's *assertions* →
    # the `agent` kind (0.7, ages ~7d). Touched files carry real `fs.path` ids, so
    # in a live workspace they unify with the filesystem/git/ruby nodes.
    module AgentSession
      module_function

      SESSION_KEY = { scheme: "agent.session", key: "s1" }.freeze
      INDEX_KEY = { scheme: "agent.sessions", key: "local" }.freeze

      # The live demo session is the first; older ones fill out the index list.
      SESSIONS = [
        { key: "s1", days_ago: 0, task: "add agent provider",
          change: "diff: agent_session provider (+evidence kind)",
          files: [["lib/hcolumns/providers/agent_session.rb", "+221", true],
                  ["lib/hcolumns/evidence.rb", "+1", false],
                  ["lib/hcolumns.rb", "+1", false],
                  ["spec/providers/agent_session_spec.rb", "+38", false]],
          test: ["rspec — 84 examples", :behavior], log: "0 failures (0.9s)",
          # captured output for the `output` content facet (a real runner/log
          # provider would fill these; here they're representative)
          test_output: [
            "$ bundle exec rspec",
            "................................................ (84)",
            "",
            "Finished in 0.90 seconds (files took 0.17s to load)",
            "84 examples, 0 failures"
          ],
          log_output: [
            "[12:00:03] suite start — seed 12345",
            "[12:00:04] 0 failures (0.9s)",
            "[12:00:04] done"
          ],
          # the agent's workflow phase over the timeline — drives the live modes
          phases: [[0.0, :editing], [4.0, :testing], [5.5, :reviewing]],
          # representative hunks, shown in the preview pane (the diff body lives on
          # the change node; a real agent/diff provider would fill these for real)
          hunks: {
            "lib/hcolumns/providers/agent_session.rb" => [
              "+    module AgentSession",
              "+      def session_events(spec, now:)",
              "+        # nodes + timed observations for one session",
              "+      end",
              "+    end"
            ],
            "lib/hcolumns/evidence.rb" => [
              "       behavior:   { ... half_life_days: 14.0 },",
              "+      agent:      { reliability: 0.7, half_life_days: 7.0 },",
              "       history:    { ... half_life_days: 90.0 },"
            ],
            "lib/hcolumns.rb" => [
              "+    require_relative \"hcolumns/providers/agent_session\""
            ],
            "spec/providers/agent_session_spec.rb" => [
              "+    RSpec.describe HColumns::Providers::AgentSession do",
              "+      # route + confidence specs",
              "+    end"
            ]
          } },
        { key: "s2", days_ago: 2, task: "fix TUI staircase in raw mode",
          change: "diff: emit CR+LF on paint",
          files: [["lib/hcolumns/tui.rb", "+6", true]],
          test: ["rspec — 74 examples", :behavior], log: "0 failures (0.8s)" },
        { key: "s3", days_ago: 5, task: "rework confidence into two modes",
          change: "diff: deterministic vs probabilistic",
          files: [["lib/hcolumns/evidence.rb", "+18", true],
                  ["lib/hcolumns/observation.rb", "+9", false],
                  ["lib/hcolumns/edge.rb", "+12", false]],
          test: ["rspec — 71 examples", :behavior], log: "0 failures (0.9s)" }
      ].freeze

      def session_id
        Identity.id_for(**SESSION_KEY)
      end

      def index_id
        Identity.id_for(**INDEX_KEY)
      end

      def spec_for(key)
        SESSIONS.find { |s| s[:key] == key }
      end

      # One session as an ordered list of timed events plus its root node. Each
      # entry is { after:, kind: :node | :observe, payload: }. `after` is the live
      # release timeline (seconds); the observation's observed_at is the session's
      # logical time (now − days_ago), so older sessions decay and rank lower.
      def session_events(spec, now:)
        at = now - (spec[:days_ago] * Evidence::DAY_SECONDS)
        node = lambda do |type, identity, name|
          Node.new(type: type, identity: identity, properties: { name: name, path: name })
        end

        phases = spec[:phases] || [[0.0, :editing]]
        session_with = lambda do |phase|
          Node.new(type: :Session, identity: { scheme: "agent.session", key: spec[:key] },
                   properties: { name: "Task: #{spec[:task]}", phase: phase })
        end
        session = session_with.(phases.first.last)
        agent   = node.(:Agent, { scheme: "agent", key: "claude" }, "claude")
        change  = Node.new(type: :ProposedChange, identity: { scheme: "agent.change", key: "#{spec[:key]}:c1" },
                           properties: { name: spec[:change], hunks: spec[:hunks] || {} })
        files   = spec[:files].map { |path, churn, focus| [node.(:SourceFile, { scheme: "fs.path", key: "local:/repo/#{path}" }, path), churn, focus] }
        test    = Node.new(type: :TestRun, identity: { scheme: "agent.test", key: "#{spec[:key]}:t1" },
                           properties: { name: spec[:test][0], path: spec[:test][0], output: spec[:test_output] })
        log     = Node.new(type: :LogLine, identity: { scheme: "agent.log", key: "#{spec[:key]}:l1" },
                           properties: { name: spec[:log], path: spec[:log], output: spec[:log_output] })

        add = ->(n) { { kind: :node, payload: n } }
        obs = lambda do |subject, object, type, kind, summary, weight: 1.0|
          { kind: :observe,
            payload: Observation.new(provider: :agent, subject_id: subject.id, target_id: object.id,
                                     edge_type: type, weight: weight, evidence_kind: kind,
                                     observed_at: at, evidence_summary: summary) }
        end

        timed = [
          [0.0, add.(session)],
          [0.0, add.(agent)],
          [0.0, obs.(session, agent, :DRIVEN_BY, :structure, "session actor")],
          [1.0, add.(change)],
          [1.0, obs.(session, change, :PROPOSES, :agent, "proposed to satisfy the task")]
        ]
        files.each_with_index do |(file, churn, focus), i|
          t = 1.6 + (i * 0.5)
          timed << [t, add.(file)]
          timed << [t, obs.(change, file, :TOUCHES, :structure, "diff hunk (#{churn})")]
          timed << [t, obs.(change, file, :FOCUSES_ON, :agent, "primary file of the change")] if focus
        end
        tail = 1.6 + (files.size * 0.5)
        timed += [
          [tail + 0.4, add.(test)],
          [tail + 0.4, obs.(change, test, :VERIFIED_BY, spec[:test][1], "ran the suite after the edit")],
          [tail + 1.0, add.(log)],
          [tail + 1.0, obs.(test, log, :EMITTED, spec[:test][1], "suite summary line")]
        ]

        # the agent declares each phase change by re-emitting the Session node with
        # a new :phase (latest fold wins) — the event that drives the live modes.
        phases.drop(1).each { |after, phase| timed << [after, add.(session_with.(phase))] }

        # stable-sort by release time (the Feed releases sequentially)
        entries = timed.each_with_index.sort_by { |(after, _e), i| [after, i] }.map(&:first)
        { session: session, at: at, entries: entries.map { |after, e| e.merge(after: after) } }
      end

      def script(now:)
        session_events(spec_for("s1"), now: now)[:entries]
      end

      # The frozen graph for the live demo session alone (timeline collapsed).
      def build(now:)
        graph = Graph.new
        feed(now: now).release(Float::INFINITY, into: graph)
        graph
      end

      def feed(now:, log: EventLog.new)
        Feed.new(script(now: now), log: log)
      end

      # The sessions index: a root node with a HAS_SESSION edge to each session,
      # ranked newest-first (recency). Every session's route is folded in, so you
      # can descend into any of them — except `live_key`, left as a bare node whose
      # route a Feed streams in (the live list walk).
      def sessions_graph(now:, live_key: nil)
        graph = Graph.new
        index = Node.new(type: :Sessions, identity: INDEX_KEY, properties: { name: "agent sessions" })
        graph.add_node(index)

        SESSIONS.each do |spec|
          built = session_events(spec, now: now)
          if spec[:key] == live_key
            graph.add_node(built[:session]) # shell only; the route arrives via the Feed
          else
            built[:entries].each { |e| e[:kind] == :node ? graph.add_node(e[:payload]) : graph.observe(e[:payload]) }
          end
          graph.observe(Observation.new(
                          provider: :agent, subject_id: index.id, target_id: built[:session].id,
                          edge_type: :HAS_SESSION, weight: 1.0, evidence_kind: :structure,
                          observed_at: built[:at],
                          evidence_summary: "#{spec[:files].size} file(s) · #{spec[:test][0]}"
                        ))
        end
        graph
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
