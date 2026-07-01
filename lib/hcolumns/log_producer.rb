# frozen_string_literal: true

module HColumns
  # The producer side, out of process: replays a timed event script into an
  # append-only JSONL log in real wall-clock time — the way a live coding agent
  # would append events as it works. It shares nothing with any consumer but the
  # file: run `hcol produce session f.jsonl` in one terminal and `hcol walk f.jsonl
  # --live` (or `serve`) in another, and the columns grow as lines land.
  #
  # Clock and sleeper are injected so a test can drive the timeline deterministically
  # (advance a fake clock instead of really sleeping). The script is a list of
  # `{ after:, kind:, payload: }` in time order (exactly what AgentSession emits).
  class LogProducer
    def initialize(script, io:, clock: -> { Time.now }, sleeper: ->(s) { sleep(s) })
      @script = script
      @io = io
      @clock = clock
      @sleeper = sleeper
    end

    # Write each event at its scheduled offset from a start time, then the eof
    # marker. Flushes per line so a tailing consumer sees each event immediately.
    def run
      start = @clock.call
      @script.each do |entry|
        wait = (start + entry[:after]) - @clock.call
        @sleeper.call(wait) if wait.positive?
        emit(Persistence.line_for(kind: entry[:kind], payload: entry[:payload]))
      end
      emit(Persistence.eof_line)
    end

    private

    def emit(line)
      @io.puts(line)
      @io.flush
    end
  end
end
