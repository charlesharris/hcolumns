# frozen_string_literal: true

module HColumns
  # The append-only source of truth. Everything that changes state is an event
  # appended here; the Graph is a *projection* folded from the log (replay), so
  # "live" and "frozen" views are both just folds — live keeps folding as the log
  # grows, frozen folds up to some seq. This is the hugel3 pattern (immutable log
  # + derived projection) finally slotted under the read-model, behind the seam
  # the architecture kept open from layer one.
  #
  # Three event kinds today: :node (a node came into being), :observe (a provider
  # or the agent asserted an edge — payload is an Observation), and :flag (a human
  # up/down/exclude/clear judgment on a node — the first *interaction* event; the
  # payload is a plain hash, and a later flag on the same node supersedes the
  # earlier one, so "clear" is the undo). :retract (a general undo counter-event)
  # remains designed-in and deferred (see docs/STATUS.md).
  class EventLog
    Event = Struct.new(:seq, :at, :kind, :payload, keyword_init: true)

    def initialize
      @events = []
    end

    attr_reader :events

    # Append an event, stamping it with the next sequence number. `at` is the
    # logical time of the event (an Observation's observed_at); nil for nodes.
    def append(kind:, payload:, at: nil)
      event = Event.new(seq: @events.length, at: at, kind: kind, payload: payload)
      @events << event
      event
    end

    # How many events have been recorded — the cheap change-detector a live
    # consumer polls (`version` grew => re-fold the tail and repaint).
    def version
      @events.length
    end

    # Events at or after `seq` (the tail a consumer hasn't folded yet).
    def since(seq)
      @events[seq..] || []
    end

    # Fold the given events into `graph`, mutating the projection directly (the
    # apply_* path, which does *not* re-record — replaying must not re-log).
    def fold(events, into:)
      events.each do |event|
        case event.kind
        when :node then into.apply_node(event.payload)
        when :observe then into.apply_observe(event.payload)
        when :flag then into.apply_flag(event.payload)
        end
      end
      into
    end

    # Replay the whole log into a fresh graph — the projection from scratch. Equal
    # to a graph built by folding the same events incrementally (the round-trip
    # that proves the log really is the source of truth).
    def project
      fold(@events, into: Graph.new)
    end
  end
end
