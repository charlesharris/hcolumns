# frozen_string_literal: true

module HColumns
  # The Miller-column traversal state: a stack of frames, each a node viewed under
  # one of its modes (tabs). The rightmost frame is active; its cursor moves over
  # the active panel's focusable items. Descending ("into") pushes the selected
  # item's target; "back" pops. The frames' nodes are the breadcrumb.
  #
  # Each frame carries the modes a ModeResolver ranked for its node (the tabs); the
  # head is the auto mode it opens on. Switching tabs (`next_tab`) re-views the same
  # node under another mode — cheap (re-score/regroup, no re-pull). Panels are
  # pulled from a `source` (a Workspace) whose graph may load neighbors lazily.
  class Cascade
    Frame = Struct.new(:node, :modes, :tab, :cursor, :panel, :pinned, keyword_init: true)

    attr_reader :frames, :now

    def initialize(source, root_id, now:, feed: nil, resolver: ModeResolver.new, session: nil, floor: 0.0)
      @source = source
      @now = now
      @feed = feed
      @resolver = resolver
      @session = session
      @floor = floor
      @frames = [make_frame(root_id)]
    end

    def active
      @frames.last
    end

    def active_panel
      active.panel
    end

    # Focusable items of the active panel in display order; the cursor indexes this
    # flat list (relation headers / facet text lines are skipped).
    def active_entries
      active_panel.items
    end

    def selected_entry
      active_entries[active.cursor]
    end

    # The mode (tab) the active frame is open on, and the node it shows.
    def active_mode
      active.modes[active.tab]
    end

    def current_node
      active.node
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

    # Descend into the selected item's target, pushing its column as the new active
    # frame (opened on its own auto mode). No-op if nothing is selected.
    def into
      item = selected_entry
      return self unless item&.target_id

      @frames.push(make_frame(item.target_id))
      self
    end

    def back
      @frames.pop if @frames.length > 1
      self
    end

    # --- tabs (modes) -------------------------------------------------------

    # Cycle the active frame to its next/prev tab and re-view the node under it.
    def next_tab
      cycle_tab(1)
    end

    def prev_tab
      cycle_tab(-1)
    end

    def cycle_tab(delta)
      frame = active
      return self if frame.modes.length <= 1

      frame.tab = (frame.tab + delta) % frame.modes.length
      frame.pinned = true # a manual choice — phase changes no longer move this column
      build_panel(frame)
      self
    end

    # Jump the active frame straight to its details facet (the old `i` inspector,
    # now just one of the tabs).
    def show_details
      idx = active.modes.index { |m| m.name == :details }
      return self unless idx

      active.tab = idx
      active.pinned = true
      build_panel(active)
      self
    end

    # A global confidence floor applied to every lens-backed panel (the `[`/`]`
    # retune); facets ignore it. Rebuilds the walked path.
    def adjust_floor(delta)
      @floor = (@floor + delta).clamp(0.0, 1.0)
      rebuild!
    end

    # A short "default · floor 0.35" label for the status line.
    def status_label
      label = active_mode.name.to_s
      @floor.positive? ? "#{label} · floor #{format('%.2f', @floor)}" : label
    end

    # The session's current phase (what the agent is doing), or nil outside a
    # session — what biases the auto modes.
    def phase
      @session&.phase
    end

    # --- live feed (the agent as event source) ------------------------------

    # Advance the live feed to `elapsed` seconds, rebuilding the walked path if any
    # events landed. Returns true iff the projection grew (the repaint signal).
    def tick(elapsed)
      return false unless @feed && @feed.release(elapsed, into: @source.graph)

      rebuild!
      true
    end

    def live?
      !@feed.nil?
    end

    # The panel the active selection would open — shown as a live preview, under
    # the previewed node's own auto mode.
    def preview_panel
      item = selected_entry
      return nil unless item&.target_id

      node = @source.graph.node(item.target_id)
      node && build_panel_for(node, @resolver.auto(node, session: @session))
    end

    # The breadcrumb: the node at each level of the walked path.
    def trail
      @frames.map(&:node)
    end

    # Rebuild every frame from source (after a retune / feed tick / phase change),
    # preserving the walked path. Non-pinned frames re-resolve their modes so the
    # auto tab follows the current phase; a frame the user pinned (via Tab/details)
    # keeps its mode. Cursors clamp to the new item lists.
    def rebuild!
      @frames.each do |frame|
        frame.node = @source.graph.node(frame.node.id) || frame.node # pick up live property changes
        unless frame.pinned
          frame.modes = @resolver.modes_for(frame.node, session: @session)
          frame.tab = 0
        end
        build_panel(frame)
      end
      self
    end

    private

    def make_frame(node_id)
      node = @source.graph.node(node_id)
      frame = Frame.new(node: node, modes: @resolver.modes_for(node, session: @session),
                        tab: 0, cursor: 0, pinned: false)
      build_panel(frame)
      frame
    end

    def build_panel(frame)
      frame.panel = build_panel_for(frame.node, frame.modes[frame.tab])
      last = [frame.panel.items.length - 1, 0].max
      frame.cursor = frame.cursor.to_i.clamp(0, last)
      frame.panel
    end

    def build_panel_for(node, mode)
      mode = floored(mode) if @floor.positive? && mode.respond_to?(:lens)
      mode.panel(node, @source, now: @now)
    end

    # A copy of a lens mode with the confidence floor applied (the live retune).
    def floored(mode)
      LensMode.new(name: mode.name, lens: mode.lens.with_floor(@floor))
    end
  end
end
