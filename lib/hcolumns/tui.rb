# frozen_string_literal: true

require "io/console"

module HColumns
  # The interactive driver: read a key, mutate the cascade, repaint. Deliberately
  # thin — all navigation logic lives in Cascade (which is unit-tested without a
  # TTY). Supports arrow keys and vim hjkl.
  class TUI
    class NoTTY < StandardError; end

    ETX = 3 # Ctrl-C

    def initialize(cascade, renderer: Renderers::CascadeText.new, out: $stdout, input: $stdin)
      @cascade = cascade
      @renderer = renderer
      @out = out
      @input = input
    end

    def run
      raise NoTTY, "hcol walk needs an interactive terminal" unless @input.tty? && @out.tty?

      @started = true
      @out.print("\e[?25l") # hide cursor
      @input.raw do
        loop do
          paint
          case read_key
          when :up, "k" then @cascade.up
          when :down, "j" then @cascade.down
          when :right, "l", :enter then @cascade.into
          when :left, "h" then @cascade.back
          when "q", :ctrl_c, :escape then break
          end
        end
      end
    ensure
      if @started
        @out.print("\e[?25h\e[0m") # restore cursor + reset attributes
        @out.puts
      end
    end

    private

    def paint
      @out.print("\e[2J\e[H") # clear screen, home
      @out.print(@renderer.render(@cascade))
      @out.flush
    end

    def read_key
      char = @input.getch
      return :ctrl_c if char.ord == ETX

      case char
      when "\e" then read_escape
      when "\r", "\n" then :enter
      else char
      end
    end

    # An ESC alone, or the start of an arrow-key sequence (ESC [ A/B/C/D).
    def read_escape
      return :escape unless @input.getch == "["

      { "A" => :up, "B" => :down, "C" => :right, "D" => :left }.fetch(@input.getch, :other)
    end
  end
end
