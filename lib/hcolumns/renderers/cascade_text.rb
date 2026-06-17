# frozen_string_literal: true

module HColumns
  module Renderers
    # Renders a Cascade as side-by-side Miller columns: a breadcrumb, the stack of
    # frames (each a narrow column with its selected entry marked), a live preview
    # of the active selection, and a detail line for the highlighted entry.
    #
    # Width math is done on plain text; color is applied last, so alignment holds
    # whether or not ANSI is on (color: false is used by golden tests).
    class CascadeText
      DEFAULT_COL_WIDTH = 22 # used when width is unconstrained (non-interactive / tests)
      MIN_COL_WIDTH = 16     # below this names are unreadable — clip columns instead of squishing
      MAX_COL_WIDTH = 44     # don't let a lone column sprawl across a wide terminal
      SEP = " │ "

      MATURITY = Text::MATURITY_GLYPH
      RELATION = Text::RELATION_GLYPH

      STYLE = {
        header:    ->(s) { "\e[34;1m#{s}\e[0m" }, # blue bold
        active:    ->(s) { "\e[7m#{s}\e[0m" },    # reverse video (the live cursor)
        committed: ->(s) { "\e[1m#{s}\e[0m" },    # bold (a selection we descended through)
        preview:   ->(s) { "\e[2m#{s}\e[0m" },    # dim
        normal:    ->(s) { s }
      }.freeze

      def initialize(color: true)
        @color = color
      end

      # Render the cascade to fit a `width` × `height` viewport. With neither given
      # (non-interactive / tests) it falls back to a fixed column width and no
      # clipping — the deterministic golden form. With a width, it shows the
      # rightmost columns that fit (the breadcrumb keeps the whole trail) and grows
      # each column to use the available room; with a height it clamps vertically.
      def render(cascade, width: nil, height: nil)
        visible, clipped = clip_to_width(build_panels(cascade), width)
        col_width = column_width(visible.length, width)

        crumb = truncate(breadcrumb(cascade, clipped: clipped), width)
        info  = detail(cascade).split("\n").map { |line| truncate(line, width) }
        body  = columns(visible, col_width, body_rows(height, info.length))

        [crumb, "", *body, "", *info, truncate(hint, width)].join("\n")
      end

      private

      def build_panels(cascade)
        panels = cascade.frames.each_with_index.map do |frame, i|
          active = i == cascade.frames.length - 1
          tab_cell(frame, active) + panel_cells(frame.panel, frame.cursor, active ? :active : :committed)
        end
        preview = cascade.preview_panel
        if preview && !preview.empty?
          panels << ([{ t: "preview", s: :preview }] + panel_cells(preview, -1, :preview, preview: true))
        end
        panels
      end

      # The per-column tab strip: the modes a column offers, the open one bracketed.
      def tab_cell(frame, active)
        strip = frame.modes.each_with_index.map { |m, i| i == frame.tab ? "[#{m.name}]" : m.name.to_s }.join(" ")
        [{ t: strip, s: active ? :header : :preview }]
      end

      # Keep the rightmost panels (active + preview + recent ancestors) that fit at
      # the minimum width; older columns scroll off the left. Returns [panels, clipped?].
      def clip_to_width(panels, width)
        return [panels, false] unless width

        fits = [(width + SEP.length) / (MIN_COL_WIDTH + SEP.length), 1].max
        panels.length <= fits ? [panels, false] : [panels.last(fits), true]
      end

      # Share the viewport evenly across the visible columns, between a readable
      # minimum and a sane maximum. Never wider than the viewport itself.
      def column_width(count, width)
        return DEFAULT_COL_WIDTH unless width

        usable = width - ((count - 1) * SEP.length)
        [[usable / count, 1].max, MAX_COL_WIDTH].min
      end

      def body_rows(height, info_lines)
        return nil unless height

        # chrome = breadcrumb + blank + blank + detail lines + hint
        [height - (4 + info_lines), 1].max
      end

      # A panel renders to an array of {t:, s:} cells (one per visual row). Sections
      # contribute a heading (if any), then plain display lines, then focusable
      # items; the cursor indexes the flattened items only.
      def panel_cells(panel, cursor, selected_style, preview: false)
        cells = []
        flat = 0
        panel.sections.each do |section|
          cells << { t: heading_text(section), s: preview ? :preview : :header } if section.heading
          section.lines.each { |line| cells << { t: line, s: preview ? :preview : :normal } }
          section.items.each do |item|
            selected = flat == cursor
            mark = selected ? "▸" : " "
            glyph = item.glyph || MATURITY.fetch(item.maturity, "·")
            style = preview ? :preview : (selected ? selected_style : :normal)
            cells << { t: "#{mark} #{glyph} #{short(item.label)}", s: style }
            flat += 1
          end
        end
        cells << { t: "(leaf)", s: preview ? :preview : :normal } if panel.empty?
        cells
      end

      # A relation-family heading gets its glyph; a composite facet heading (which
      # has spaces, e.g. "how it's reached — incoming (2)") prints as-is.
      def heading_text(section)
        h = section.heading
        h.include?(" ") ? h : "#{RELATION[h.to_sym]} #{h}"
      end

      def columns(panels, col_width, max_rows)
        height = panels.map(&:length).max || 0
        overflow = max_rows && height > max_rows
        shown = overflow ? [max_rows - 1, 1].max : height

        rows = (0...shown).map do |row|
          panels.map { |p| paint(p[row], col_width) }.join(SEP)
        end
        rows << overflow_row(panels, shown, col_width) if overflow
        rows
      end

      # A dim "↓ +N" under each column whose entries ran past the visible rows.
      def overflow_row(panels, shown, col_width)
        panels.map do |p|
          hidden = p.length - shown
          paint(({ t: "  ↓ +#{hidden}", s: :preview } if hidden.positive?), col_width)
        end.join(SEP)
      end

      def paint(cell, col_width)
        return " " * col_width unless cell

        text = fit(cell[:t], col_width)
        @color ? STYLE[cell[:s]].call(text) : text
      end

      def breadcrumb(cascade, clipped: false)
        crumbs = "  #{clipped ? '‹ ' : ''}" + cascade.trail.map(&:name).join("  ›  ")
        "#{crumbs}    [mode: #{cascade.status_label}]"
      end

      # Shorten a chrome line (breadcrumb / detail / hint) to the viewport width.
      def truncate(str, width)
        return str unless width && str.length > width
        return str[0, width] if width <= 1

        "#{str[0, width - 1]}…"
      end

      def detail(cascade)
        item = cascade.selected_entry
        return "  (nothing selected)" unless item

        line = "  #{item.label}"
        line += "  #{item.reason}" if item.reason && !item.reason.empty?
        line
      end

      def hint
        "  ↑↓/jk move · →/l descend · ←/h back · Tab modes · i details · [ ] floor · q quit"
      end

      # Basename a path-like label for narrow columns; leave composite labels
      # (which contain spaces, e.g. a diff row or a details edge) intact.
      def short(label)
        label.include?(" ") ? label : label.split("/").last
      end

      def fit(str, width)
        len = str.length
        return str + (" " * (width - len)) if len < width
        return str if len == width

        str[0, width - 1] + "…"
      end
    end
  end
end
