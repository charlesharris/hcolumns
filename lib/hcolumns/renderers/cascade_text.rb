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
      COL_WIDTH = 22
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

      def render(cascade)
        panels = cascade.frames.each_with_index.map do |frame, i|
          active = i == cascade.frames.length - 1
          panel(frame.column, frame.cursor, active ? :active : :committed)
        end

        preview = cascade.preview_column
        panels << panel(preview, -1, :preview, preview: true) if preview && !preview.empty?

        [breadcrumb(cascade), "", *columns(panels), "", detail(cascade), hint].join("\n")
      end

      private

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

      def columns(panels)
        height = panels.map(&:length).max || 0
        (0...height).map do |row|
          panels.map { |p| paint(p[row]) }.join(SEP)
        end
      end

      def paint(cell)
        return " " * COL_WIDTH unless cell

        text = fit(cell[:t], COL_WIDTH)
        @color ? STYLE[cell[:s]].call(text) : text
      end

      def breadcrumb(cascade)
        "  " + cascade.trail.map(&:name).join("  ›  ")
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
        "  ↑↓/jk move · →/l descend · ←/h back · q quit"
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
