# frozen_string_literal: true

require "json"
require "stringio"

module HColumns
  # JSONL persistence for the event log — the hügel "the mound persists" step.
  # The log is the source of truth; serialize each event to one line, replay on
  # load. Because the Graph is a *projection* folded from the log (see EventLog),
  # persisting the log is all it takes for a session to survive a restart — no
  # separate graph snapshot, and undo/frozen-at-seq keep working because the log
  # is intact.
  #
  # The one subtlety is fidelity: replay-from-disk must be *behaviorally* the same
  # as replay-in-memory, not merely structurally close. JSON drops the two Ruby
  # types our payloads carry — Symbols (edge types, evidence kinds, and a Session's
  # `:phase`, where a plain string would silently disable phase biasing) and Time
  # (an observation's `observed_at`, which drives decay). Codec restores both.
  module Persistence
    module_function

    # Dump every event as one JSON line (seq order == append order == replay order).
    def dump(log, io)
      log.events.each { |event| io.puts(JSON.generate(event_to_h(event))) }
    end

    def dump_string(log)
      io = StringIO.new
      dump(log, io)
      io.string
    end

    # Replay a JSONL stream into a fresh EventLog. append() re-stamps seq from
    # position, so the persisted "seq" is only for human inspection — loading in
    # line order reproduces it exactly. An `eof` marker (a live producer writes one
    # when its stream ends) is skipped, so a *live* log is also a valid snapshot.
    def load(io)
      log = EventLog.new
      io.each_line do |line|
        parsed = parse_line(line)
        next if parsed.nil? || parsed == :eof

        log.append(kind: parsed[:kind], at: parsed[:at], payload: parsed[:payload])
      end
      log
    end

    def load_string(string)
      load(StringIO.new(string))
    end

    # One JSONL line -> { kind:, at:, payload: }; nil for a blank line; :eof for
    # the end-of-stream marker. The seam the TailReader folds through.
    def parse_line(line)
      line = line.strip
      return nil if line.empty?

      h = JSON.parse(line)
      return :eof if h["eof"]

      kind = h["kind"].to_sym
      { kind: kind, at: Codec.load(h["at"]), payload: payload_from_h(kind, h["payload"]) }
    end

    # Serialize a single event to a JSONL line — what a producer appends as the
    # agent works (seq is left nil; the consumer re-stamps it on load). `at`
    # defaults to the payload's observed_at (an Observation), else nil (a Node).
    def line_for(kind:, payload:, at: :derive)
      at = (payload.respond_to?(:observed_at) ? payload.observed_at : nil) if at == :derive
      JSON.generate(entry_to_h(seq: nil, at: at, kind: kind, payload: payload))
    end

    # The end-of-stream marker: tells a TailReader the producer is finished (the
    # web badge flips to "✓ complete"). Not an event — load() and fold() skip it.
    def eof_line
      JSON.generate({ "eof" => true })
    end

    # The log's entrypoint: the first node to come into being. Both the frozen
    # session (its Session node) and the sessions index (its index node) put their
    # root at seq 0, so this needs no header — the log stays pure events.
    def root_id(log)
      log.events.find { |e| e.kind == :node }&.payload&.id
    end

    # --- event <-> hash ---

    def event_to_h(event)
      entry_to_h(seq: event.seq, at: event.at, kind: event.kind, payload: event.payload)
    end

    def entry_to_h(seq:, at:, kind:, payload:)
      {
        "seq" => seq,
        "at" => Codec.dump(at),
        "kind" => kind.to_s,
        "payload" => payload_to_h(kind, payload)
      }
    end

    def payload_to_h(kind, payload)
      case kind
      when :node then node_to_h(payload)
      when :observe then observation_to_h(payload)
      when :flag, :turn then Codec.dump(payload) # plain symbol-keyed hashes; Codec keeps Symbols/Time
      else raise ArgumentError, "cannot serialize event kind #{kind.inspect}"
      end
    end

    def payload_from_h(kind, h)
      case kind
      when :node then node_from_h(h)
      when :observe then observation_from_h(h)
      when :flag, :turn then Codec.load(h)
      else raise ArgumentError, "cannot load event kind #{kind.inspect}"
      end
    end

    def node_to_h(node)
      {
        "id" => node.id,
        "type" => node.type.to_s,
        "identity" => Codec.dump(node.identity),
        "labels" => Codec.dump(node.labels),
        "properties" => Codec.dump(node.properties)
      }
    end

    def node_from_h(h)
      Node.new(
        type: h["type"].to_sym,
        identity: Codec.load(h["identity"]),
        labels: Codec.load(h["labels"]),
        properties: Codec.load(h["properties"]),
        id: h["id"] # pin the persisted id (it equals the identity hash, but be exact)
      )
    end

    def observation_to_h(obs)
      {
        "provider" => obs.provider.to_s,
        "subject_id" => obs.subject_id,
        "target_id" => obs.target_id,
        "edge_type" => obs.edge_type.to_s,
        "weight" => obs.weight,
        "evidence_kind" => obs.evidence_kind.to_s,
        "evidence_summary" => obs.evidence_summary,
        "observed_at" => Codec.dump(obs.observed_at)
      }
    end

    def observation_from_h(h)
      Observation.new(
        provider: h["provider"].to_sym,
        subject_id: h["subject_id"],
        target_id: h["target_id"],
        edge_type: h["edge_type"].to_sym,
        weight: h["weight"],
        evidence_kind: h["evidence_kind"].to_sym,
        evidence_summary: h["evidence_summary"],
        observed_at: Codec.load(h["observed_at"])
      )
    end

    # A JSON codec that round-trips the two things plain JSON drops from our
    # payloads: Ruby Symbols and Time.
    #
    #   * Symbol value -> {"$sym": "editing"};  Time -> {"$time": "<rational>"}.
    #   * A hash whose keys are ALL symbols (the common case — a Node's properties)
    #     encodes as a plain object and re-symbolizes on load, so the JSONL stays
    #     readable. A hash with any non-symbol key (a diff's `hunks`, keyed by file
    #     path) falls back to {"$map": [[k, v], ...]} so key *types* survive exactly.
    #
    # A plain object is never one of the sentinel forms by construction, so decoding
    # is unambiguous (our data has no key literally named "$sym"/"$time"/"$map").
    module Codec
      SYM = "$sym"
      TIME = "$time"
      MAP = "$map"

      module_function

      def dump(value)
        case value
        when Symbol then { SYM => value.to_s }
        when Time then { TIME => value.to_r.to_s }
        when Array then value.map { |v| dump(v) }
        when Hash then dump_hash(value)
        else value # String, Integer, Float, true, false, nil
        end
      end

      def dump_hash(hash)
        if hash.keys.all? { |k| k.is_a?(Symbol) }
          hash.each_with_object({}) { |(k, v), h| h[k.to_s] = dump(v) }
        else
          { MAP => hash.map { |k, v| [dump(k), dump(v)] } }
        end
      end

      def load(value)
        case value
        when Array then value.map { |v| load(v) }
        when Hash then load_hash(value)
        else value
        end
      end

      def load_hash(hash)
        return hash[SYM].to_sym if sentinel?(hash, SYM)
        return Time.at(Rational(hash[TIME])) if sentinel?(hash, TIME)
        return hash[MAP].each_with_object({}) { |(k, v), h| h[load(k)] = load(v) } if sentinel?(hash, MAP)

        hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = load(v) }
      end

      def sentinel?(hash, tag)
        hash.size == 1 && hash.key?(tag)
      end
    end
  end
end
