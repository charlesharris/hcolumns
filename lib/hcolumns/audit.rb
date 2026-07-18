# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module HColumns
  # The append-only record of what was dispatched, what ran, and what it did
  # (hc-4s4, layer 34b). Charris's call, and the compensating control that makes
  # the permission trade defensible: an unattended agent cannot be gated by an
  # interactive approval loop — you would be answering a prompt per Bash call,
  # which defeats dispatch entirely — so instead of asking permission at the
  # moment of action, we keep an unforgeable-by-omission record of every action.
  #
  # This is DETECTIVE, not preventive, and the distinction is the whole design.
  # An audit log does not stop a bad dispatch; it makes one impossible to run
  # unnoticed. That is why the preventive bounds live elsewhere and are cheap —
  # loopback-only serve, opt-in --dispatch, worktree isolation — and why this file
  # is deliberately dumb: a line per moment, never rewritten, never folded.
  #
  # Deliberately NOT the bridge log. The bridge log is an event SOURCE that gets
  # projected into the graph, and projection is lossy on purpose (latest-fold-wins
  # collapses a task's states into one node, which is exactly what makes the UI
  # flip ◌→◐→✓ in place). An audit trail must not collapse: the whole value is
  # every state, in order, including the ones a later event superseded. Separate
  # file, separate lifetime, greppable with no hcolumns in the loop.
  class Audit
    FILENAME = "audit.jsonl"

    # Every record carries these, so a line is self-describing without its
    # neighbours: when, what happened, which task, and who asked for it.
    def initialize(path:, clock: -> { Time.now }, warn: method(:warn))
      @path = path
      @clock = clock
      @warn = warn
    end

    attr_reader :path

    def self.for_root(root, clock: -> { Time.now })
      new(path: File.join(File.expand_path(root), ".hcolumns", FILENAME), clock: clock)
    end

    # Append one record. Fields are merged over the envelope, so a caller can add
    # anything without a schema change — the reader is grep and jq, not a parser.
    #
    # A write failure WARNS rather than raises, and the trade-off is deliberate: a
    # full disk mid-run should not kill work that is already in flight and already
    # partly recorded. It is loud on stderr precisely because a silent audit gap is
    # the one failure mode that would make this file worthless.
    def record(event, **fields)
      FileUtils.mkdir_p(File.dirname(@path))
      line = { at: @clock.call.utc.iso8601, event: event.to_s }.merge(fields)
      File.open(@path, "a") { |f| f.puts(JSON.generate(line)) }
      line
    rescue StandardError => e
      @warn.call("hcol audit: could not record #{event} (#{e.message})")
      nil
    end

    # Read the trail back, oldest first. Malformed lines are SKIPPED rather than
    # fatal — a truncated last line (a crash mid-append) must not make the whole
    # history unreadable, which is the failure mode that turns an audit log into a
    # thing nobody trusts.
    def entries
      return [] unless File.file?(@path)

      File.readlines(@path).filter_map do |line|
        JSON.parse(line, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
    end

    # The trail for one task, which is the question a human actually asks: "this
    # branch appeared in my repo — where did it come from and who asked for it?"
    def for_task(key)
      entries.select { |e| e[:key] == key }
    end
  end
end
