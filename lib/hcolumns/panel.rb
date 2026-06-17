# frozen_string_literal: true

module HColumns
  # What a column generalizes to once a tab can be a *facet of the thing* and not
  # only a ranked list of relations. A Panel is one mode's view of one node:
  #
  #   * focusable `items` — the rows you can put the cursor on and descend into.
  #     A lens column's items are its ranked entries; a details facet's are the
  #     node's edges; a future diff facet's would be the touched hunks. Navigation
  #     runs over `items`, uniformly, whatever the facet.
  #   * `sections` — how the panel groups itself for display (a relation family, or
  #     "incoming"/"outgoing"). A section carries items and/or plain `lines` (text
  #     a facet wants to show that isn't focusable, e.g. an identity block).
  #
  # Panels are data; rendering them (the tab strip, the cursor, side-by-side
  # layout) stays in the renderer layer — that work lands in 1b.
  class Panel
    attr_reader :node, :mode, :sections

    def initialize(node:, mode:, sections:)
      @node = node
      @mode = mode # the mode key/name that produced this view (the tab label)
      @sections = sections
    end

    # The flattened focusable list — the cursor's index space, in display order.
    def items
      sections.flat_map(&:items)
    end

    def empty?
      sections.all? { |s| s.items.empty? && s.lines.empty? }
    end
  end

  # A focusable row. `target_id` is the node descending lands on. The display
  # fields (maturity/confidence/reason) let the renderer draw the same glyph+bar a
  # column does; `detail` is extra lines a facet attaches (e.g. the confidence
  # math behind an edge), shown when the renderer wants depth.
  PanelItem = Struct.new(:label, :target_id, :maturity, :confidence, :reason, :detail, keyword_init: true) do
    def detail
      self[:detail] || []
    end
  end

  # A labeled group within a panel: focusable items, plain display lines, or both.
  PanelSection = Struct.new(:heading, :items, :lines, keyword_init: true) do
    def items
      self[:items] || []
    end

    def lines
      self[:lines] || []
    end
  end
end
