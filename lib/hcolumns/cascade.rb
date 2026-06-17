# frozen_string_literal: true

module HColumns
  # The Miller-column traversal state: a stack of frames, each a built Column plus
  # a cursor. The rightmost frame is active; its cursor moves freely. Descending
  # ("into") pushes the selected entry's target column; "back" pops. The frames'
  # roots are the breadcrumb of the route walked.
  #
  # Columns are pulled from a `source` (a Workspace) via `column_for`, which may
  # lazily load a node's neighbors on first request — so navigation logic stays
  # decoupled from where the graph comes from.
  class Cascade
    Frame = Struct.new(:column, :cursor, keyword_init: true)

    attr_reader :frames, :now

    def initialize(source, root_id, now:, feed: nil)
      @source = source
      @now = now
      @feed = feed
      @frames = [Frame.new(column: build(root_id), cursor: 0)]
    end

    def active
      @frames.last
    end

    def active_column
      active.column
    end

    # Entries of the active column in display (ranked) order; the cursor indexes
    # into this flat list, ignoring the relation-group headers.
    def active_entries
      active_column.entries
    end

    def selected_entry
      active_entries[active.cursor]
    end

    # The node currently being walked (root of the active column) and the active
    # lens — what the inspector needs to explain the selected entry.
    def current_node
      active_column.root
    end

    def lens
      @source.lens if @source.respond_to?(:lens)
    end

    def depth
      @frames.length
    end

    def up
      move(-1)
    end

    def down
      move(1)
    end

    def move(delta)
      n = active_entries.length
      return self if n.zero?

      active.cursor = (active.cursor + delta).clamp(0, n - 1)
      self
    end

    # Descend into the selected entry's target, pushing its column as the new
    # active frame. No-op if there is nothing selected.
    def into
      entry = selected_entry
      return self unless entry

      @frames.push(Frame.new(column: build(entry.target.id), cursor: 0))
      self
    end

    # Pop back toward the root (never past it).
    def back
      @frames.pop if @frames.length > 1
      self
    end

    # --- live feed (the agent as event source) ------------------------------

    # Advance the live feed to `elapsed` seconds: release any events whose time has
    # come into the graph, and rebuild the walked path if anything landed so the
    # cascade reflects them. Returns true iff the projection grew (the consumer's
    # signal to repaint). A no-op without a feed (the frozen walk).
    def tick(elapsed)
      return false unless @feed && @feed.release(elapsed, into: @source.graph)

      rebuild!
      true
    end

    def live?
      !@feed.nil?
    end

    # --- live retune (the lens knobs) ---------------------------------------

    # Cycle to the next lens preset and rebuild the walked path under it.
    def cycle_lens
      return self unless retunable?

      @source.lens = Lens.cycle(@source.lens.name)
      rebuild!
    end

    # Nudge the confidence floor (the `[`/`]` keys), clamped to [0,1].
    def adjust_floor(delta)
      return self unless retunable?

      floor = (@source.lens.tuner.floor + delta).clamp(0.0, 1.0)
      @source.lens = @source.lens.with_floor(floor)
      rebuild!
    end

    # A short "explorer · floor 0.35" label for the status line, or nil if the
    # source has no lens (e.g. a bare graph in a test).
    def lens_label
      return nil unless retunable?

      "#{@source.lens.name} · floor #{format('%.2f', @source.lens.tuner.floor)}"
    end

    # Rebuild every frame's column from source (after a lens change), preserving
    # the walked path and clamping each cursor to the new, possibly shorter list.
    def rebuild!
      @frames = @frames.map do |frame|
        column = build(frame.column.root.id)
        last = [column.entries.length - 1, 0].max
        Frame.new(column: column, cursor: frame.cursor.clamp(0, last))
      end
      self
    end

    # The column the active selection *would* open — shown as a live preview to
    # the right of the cascade, not (yet) part of the walked path.
    def preview_column
      entry = selected_entry
      entry && build(entry.target.id)
    end

    # The breadcrumb: the root node at each level of the walked path.
    def trail
      @frames.map { |f| f.column.root }
    end

    private

    def retunable?
      @source.respond_to?(:lens) && @source.respond_to?(:lens=)
    end

    def build(node_id)
      @source.column_for(node_id, now: @now)
    end
  end
end
