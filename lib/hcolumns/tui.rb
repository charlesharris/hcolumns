# frozen_string_literal: true

require "io/console"

module HColumns
  # The interactive driver: read a key, mutate the cascade, repaint. Deliberately
  # thin — all navigation logic lives in Cascade (which is unit-tested without a
  # TTY). Supports arrow keys and vim hjkl.
  class TUI
    class NoTTY < StandardError; end

    ETX = 3 # Ctrl-C
    POLL_INTERVAL = 0.1 # seconds between live-feed ticks while idle

    def initialize(cascade, renderer: Renderers::CascadeText.new, out: $stdout, input: $stdin,
                   clock: -> { Time.now })
      @cascade = cascade
      @renderer = renderer
      @out = out
      @input = input
      @clock = clock
    end

    def run
      raise NoTTY, "hcol walk needs an interactive terminal" unless @input.tty? && @out.tty?

      @started = true
      @start = @clock.call
      @out.print("\e[?25l") # hide cursor
      @prev_winch = Signal.trap("WINCH") { paint } # repaint live on terminal resize
      @input.raw do
        paint
        loop { break unless @cascade.live? ? live_step : blocking_step }
      end
    ensure
      if @started
        Signal.trap("WINCH", @prev_winch || "DEFAULT")
        @out.print("\e[?25h\e[0m") # restore cursor + reset attributes
        @out.puts
      end
    end

    private

    # One turn of the frozen walk: block for a key, act, repaint. Returns false to
    # quit. (Behaviour unchanged from before live mode.)
    def blocking_step
      handled = apply_key(read_key)
      paint unless handled == :quit
      handled != :quit
    end

    # One turn of the live walk: wait up to POLL_INTERVAL for a key. A key acts and
    # repaints; a timeout advances the feed and repaints only if the column grew —
    # so an idle cascade doesn't flicker, and a settled session behaves like the
    # frozen walk (it just waits on input). Returns false to quit.
    def live_step
      if wait_for_input
        handled = apply_key(read_key)
        paint unless handled == :quit
        handled != :quit
      else
        paint if @cascade.tick(@clock.call - @start)
        true
      end
    end

    # Block up to POLL_INTERVAL for readable input; true if a key is waiting. A
    # resize (SIGWINCH) interrupts the select — the handler already repainted, so
    # just resume waiting.
    def wait_for_input
      !IO.select([@input], nil, nil, POLL_INTERVAL).nil?
    rescue Errno::EINTR
      retry
    end

    # Apply one key to the cascade; returns :quit to stop.
    def apply_key(key)
      case key
      when :up, "k" then @cascade.up
      when :down, "j" then @cascade.down
      when :right, "l", :enter then @cascade.into
      when :left, "h" then @cascade.back
      when "r" then @cascade.cycle_lens
      when "[" then @cascade.adjust_floor(-0.05)
      when "]" then @cascade.adjust_floor(0.05)
      when "q", :ctrl_c, :escape then :quit
      end
    end

    def paint
      # In raw mode the terminal no longer maps "\n" to CR+LF, so lines would
      # stair-step to the right. Emit explicit CR+LF. The cascade is re-rendered
      # to the current terminal size each paint, so it adapts on resize.
      rows, cols = terminal_size
      @out.print("\e[2J\e[H") # clear screen, home
      @out.print(@renderer.render(@cascade, width: cols, height: rows).gsub("\n", "\r\n"))
      @out.flush
    end

    # [rows, cols] of the terminal, with a sane floor: some environments (and a
    # pty opened without a size) report 0×0 or nonsense, which would collapse every
    # column to a sliver. Treat anything too small to be real as unknown.
    def terminal_size
      rows, cols = @out.winsize
      [rows.to_i < 4 ? 24 : rows, cols.to_i < 8 ? 80 : cols]
    rescue StandardError
      [24, 80]
    end

    def read_key
      char = @input.getch
      return :ctrl_c if char.ord == ETX

      case char
      when "\e" then read_escape
      when "\r", "\n" then :enter
      else char
      end
    rescue Errno::EINTR
      retry # a resize (SIGWINCH) interrupted the read — the handler repainted; wait again
    end

    # An ESC alone, or the start of an arrow-key sequence (ESC [ A/B/C/D).
    def read_escape
      return :escape unless @input.getch == "["

      { "A" => :up, "B" => :down, "C" => :right, "D" => :left }.fetch(@input.getch, :other)
    end
  end
end
