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

    attr_reader :frames

    def initialize(source, root_id, now:)
      @source = source
      @now = now
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

    def build(node_id)
      @source.column_for(node_id, now: @now)
    end
  end
end
