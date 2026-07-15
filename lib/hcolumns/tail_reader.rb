# frozen_string_literal: true

module HColumns
  # The consumer side of the out-of-process producer: it *follows* an append-only
  # JSONL event log that a separate process is writing, folding newly-appended
  # events into a projection as they land. This is the real async producer done
  # the log-is-truth way — concurrency lives *between processes*, mediated by the
  # append-only file, so the in-memory EventLog stays single-writer and needs no
  # mutex. (The lock the STATUS kept promising was only ever necessary if you
  # insisted on one shared in-memory log across producer + consumer threads.)
  #
  # Duck-typed to stand in for a Feed — release(elapsed, into:) / log / done? — so
  # Cascade#tick and Web::App#pump drive it unchanged. `elapsed` is ignored: unlike
  # a pull Feed (the consumer decides which events are "due"), events here arrive
  # on their own; release just drains whatever the producer has written.
  class TailReader
    attr_reader :log, :path

    def initialize(path, log: EventLog.new)
      @path = path
      @log = log
      @offset = 0    # bytes consumed from the file so far
      @buffer = +""  # a partial trailing line the producer hasn't finished
      @done = false
    end

    # Fold any newly-appended events into `into` (a projection graph). Returns
    # whether anything landed — the repaint / version-bump signal the consumers
    # already key on.
    def release(_elapsed = nil, into:)
      before = @log.version
      read_new_lines.each { |line| ingest(line, into: into) }
      @log.version > before
    end

    # True once the producer has written its end-of-stream marker.
    def done?
      @done
    end

    private

    # Read the bytes appended since last call and split off complete lines; a
    # half-written trailing line stays buffered until its newline arrives. Reopens
    # the file each call (cheap, and robust to the writer being a different
    # process); missing/short-of-offset files simply yield nothing this tick.
    def read_new_lines
      return [] unless File.exist?(@path)

      data = File.open(@path, "rb") do |f|
        f.seek(@offset)
        chunk = f.read
        @offset = f.tell
        chunk
      end
      return [] if data.nil? || data.empty?

      @buffer << data
      lines = []
      lines << @buffer.slice!(0..@buffer.index("\n")).chomp while @buffer.include?("\n")
      lines
    end

    def ingest(line, into:)
      parsed = Persistence.parse_line(line)
      return if parsed.nil?

      if parsed == :eof
        @done = true
        return
      end

      # A log that speaks again isn't done — an accreting log (the agent bridge's)
      # carries stale eof markers from sessions past, and staying "complete" on one
      # would deafen every live view to what follows. Latest word wins, like :phase.
      @done = false
      @log.append(kind: parsed[:kind], at: parsed[:at], payload: parsed[:payload])
      @log.fold([@log.events.last], into: into)
    end
  end
end
