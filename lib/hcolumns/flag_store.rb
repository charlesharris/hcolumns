# frozen_string_literal: true

require "fileutils"

module HColumns
  # The first *accreting* on-disk event log: the user's flags append to
  # `.hcolumns/flags.jsonl` under the walked root, one event per line as they
  # happen, and replay into the graph at the start of the next walk — so a
  # judgment made today still shapes tomorrow's columns.
  #
  # Only flag events persist here, deliberately. Provider observations are
  # re-derivable from the world (the filesystem, git, the beads DB regrow them
  # on expansion) — persisting them would double-fold on reload and inflate
  # probabilistic confidence. The human's judgment is the one part of the mound
  # that can't be re-derived; it's the part worth keeping.
  class FlagStore
    def initialize(path)
      @path = path
    end

    attr_reader :path

    # Append one flag event (a payload hash) — called as the user flags.
    def append(payload)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, "a") { |f| f.puts(Persistence.line_for(kind: :flag, payload: payload, at: payload[:at])) }
    end

    # Replay every stored flag into `graph` (via Graph#flag, so a log-backed
    # graph records them as events too). Later lines supersede earlier ones by
    # the fold's last-flag-wins, so the file needs no compaction to be correct.
    def replay(graph)
      return 0 unless File.file?(@path)

      count = 0
      File.foreach(@path) do |line|
        parsed = Persistence.parse_line(line)
        next if parsed.nil? || parsed == :eof || parsed[:kind] != :flag

        graph.flag(**parsed[:payload])
        count += 1
      end
      count
    end
  end
end
