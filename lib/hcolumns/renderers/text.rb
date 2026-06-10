# frozen_string_literal: true

module HColumns
  module Renderers
    # Plain-text rendering of a single column: relation groups, each with its
    # ranked entries, a maturity glyph, a confidence bar, and the rank reason.
    # Deterministic given a deterministic column.
    class Text
      MATURITY_GLYPH = {
        confirmed: "●",   # ●
        reinforced: "◐",  # ◐
        suggested: "◌",   # ◌
        observed: "·"     # ·
      }.freeze

      RELATION_GLYPH = Hash.new("→").merge( # → default
        CONTAINS: "⊃",         # ⊃
        PAIR: "⇄",             # ⇄
        CO_CHANGED_WITH: "↔",  # ↔
        MENTIONS: "❡",         # ❡
        CHANGED_BY: "✎"        # ✎
      )

      NAME_WIDTH = 26

      def render(column)
        lines = ["▸ #{column.root.name}  (#{column.root.type})"]
        return (lines << "  (no related objects)").join("\n") if column.empty?

        column.groups.each do |group|
          lines << "  #{RELATION_GLYPH[group.relation]} #{group.relation}"
          group.entries.each { |e| lines << entry_line(e) }
        end
        lines.join("\n")
      end

      private

      def entry_line(entry)
        glyph = MATURITY_GLYPH.fetch(entry.maturity, "·")
        "      #{glyph} #{ljust(entry.target.name, NAME_WIDTH)} #{bar(entry.confidence)}  #{entry.rank_reason}"
      end

      def ljust(str, width)
        s = str.to_s
        s.length >= width ? s : s + (" " * (width - s.length))
      end

      def bar(confidence, slots: 5)
        filled = (confidence * slots).round.clamp(0, slots)
        ("▰" * filled) + ("▱" * (slots - filled)) # ▰▱
      end
    end
  end
end
