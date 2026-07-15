# frozen_string_literal: true

module HColumns
  # Mounts a tailed agent-bridge log into a *host* graph: a Feed decorator that,
  # whenever new events land, links the host's root to any Session node the log
  # has produced (root -HAS_SESSION-> session, a sibling stratum to HAS_BEADS).
  #
  # The edge is emitted here, at serve time, rather than written into the log:
  # the log records only what happened (path-independent, single-writer — the
  # hook), and *where the session hangs* is the host's decision. Replay the same
  # log under a different root and it mounts there. The bridge's file nodes are
  # real fs.path identities, so beyond this one seam edge the two worlds unify
  # on their own (same identity => same id).
  #
  # Duck-typed as a Feed (release / log / done?), so Web::App#pump and
  # Cascade#tick drive it unchanged.
  class BridgeMount
    def initialize(feed, root_id:, now:)
      @feed = feed
      @root_id = root_id
      @now = now
      @mounted = {}
    end

    def log
      @feed.log
    end

    def done?
      @feed.done?
    end

    # The first mounted session's node id — the host wires its SessionContext
    # (phase-following modes) off this once events have landed. nil until then.
    def session_id
      @mounted.keys.first
    end

    def release(elapsed = nil, into:)
      landed = @feed.release(elapsed, into: into)
      mount_new_sessions(into) if landed
      landed
    end

    private

    # One seam per session, once — re-observing on every release would re-append
    # evidence and inflate the edges' confidence. The seam is a PAIR: the root
    # names its session (HAS_SESSION), and the session names its project
    # (IN_PROJECT), so a walk rooted at either can reach the other — from a
    # session column, the whole directory world (files/git/beads) is one
    # descend away.
    def mount_new_sessions(graph)
      graph.nodes.each do |node|
        next unless node.identity && node.identity[:scheme] == "agent.session"
        next if @mounted[node.id]

        @mounted[node.id] = true
        seam(graph, @root_id, node.id, :HAS_SESSION, "live agent session (bridge log)")
        seam(graph, node.id, @root_id, :IN_PROJECT, "the project this session works in")
      end
    end

    def seam(graph, subject_id, target_id, type, summary)
      graph.observe(Observation.new(
                      provider: :bridge, subject_id: subject_id, target_id: target_id,
                      edge_type: type, weight: 1.0, evidence_kind: :structure,
                      observed_at: @now, evidence_summary: summary
                    ))
    end
  end
end
