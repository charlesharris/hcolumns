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
          panel(frame.column, frame.cursor, active ? :active : :committed)
        end
        preview = cascade.preview_column
        panels << panel(preview, -1, :preview, preview: true) if preview && !preview.empty?
        panels
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

      # A panel is an array of {t:, s:} cells (one per visual row).
      def panel(column, cursor, selected_style, preview: false)
        cells = []
        flat = 0
        column.groups.each do |group|
          cells << { t: "#{RELATION[group.relation]} #{group.relation}", s: preview ? :preview : :header }
          group.entries.each do |entry|
            selected = flat == cursor
            mark = selected ? "▸" : " "
            text = "#{mark} #{MATURITY.fetch(entry.maturity, '·')} #{short(entry.target.name)}"
            style = preview ? :preview : (selected ? selected_style : :normal)
            cells << { t: text, s: style }
            flat += 1
          end
        end
        cells << { t: "(leaf)", s: preview ? :preview : :normal } if column.empty?
        cells
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
        label = cascade.lens_label
        label ? "#{crumbs}    [lens: #{label}]" : crumbs
      end

      # Shorten a chrome line (breadcrumb / detail / hint) to the viewport width.
      def truncate(str, width)
        return str unless width && str.length > width
        return str[0, width] if width <= 1

        "#{str[0, width - 1]}…"
      end

      def detail(cascade)
        entry = cascade.selected_entry
        return "  (nothing selected)" unless entry

        kinds = entry.edge.evidence_kinds.join("+")
        vias = entry.provenance.map(&:provider).uniq.join(", ")
        summary = entry.provenance.filter_map(&:evidence_summary).first
        line1 = "  #{entry.target.name}  #{entry.maturity} · conf #{format('%.2f', entry.confidence)} · [#{kinds}] · via #{vias}"
        summary ? "#{line1}\n  #{summary}" : line1
      end

      def hint
        "  ↑↓/jk move · →/l descend · ←/h back · r lens · [ ] floor · q quit"
      end

      def short(name)
        name.to_s.split("/").last
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
