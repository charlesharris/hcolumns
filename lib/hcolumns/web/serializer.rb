# frozen_string_literal: true

module HColumns
  module Web
    # The web "renderer": a peer to Renderers::* that consumes the same Panel/Node
    # data the terminal renderers do, but emits plain JSON-able Hashes instead of
    # terminal text. Where the text renderers lay data into a width×height character
    # grid, this ignores geometry entirely — which is the point: it confirms the
    # cross-front-end contract lives in the Panel/Node *data*, not in any renderer's
    # signature. Pure functions, no I/O.
    module Serializer
      module_function

      # A built Panel plus the tab names a ModeResolver ranked for its node — enough
      # for a client to render the column, its tab strip, and descend (target_id).
      def panel(panel, modes:)
        {
          node: node(panel.node),
          mode: panel.mode.to_s,
          modes: modes.map(&:to_s),
          sections: panel.sections.map { |section| section(section) }
        }
      end

      def section(section)
        {
          heading: section.heading,
          lines: section.lines,
          items: section.items.map { |item| item(item) }
        }
      end

      def item(item)
        {
          label: item.label.to_s,
          target_id: item.target_id,
          maturity: jsonable(item.maturity),
          confidence: item.confidence,
          reason: item.reason,
          glyph: item.glyph,
          detail: item.detail
        }
      end

      def node(node)
        {
          id: node.id,
          type: node.type.to_s,
          name: node.name.to_s,
          labels: node.labels,
          properties: jsonable(node.properties)
        }
      end

      # Properties carry symbols and nested hashes (e.g. :phase, :hunks); keep them
      # JSON-friendly without flattening the structure.
      def jsonable(value)
        case value
        when Hash then value.each_with_object({}) { |(k, v), h| h[k.to_s] = jsonable(v) }
        when Array then value.map { |v| jsonable(v) }
        when Symbol then value.to_s
        else value
        end
      end
    end
  end
end
