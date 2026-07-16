# frozen_string_literal: true

module HColumns
  # The context stratum's facets (hc-33x) — the session's tokens, made visible.
  #
  # The counts alone ("9.2M in → 32k out") are abstract: they say a number was
  # billed, not what it WAS or where it went. These render the material behind
  # the number, at three depths: the top consumers (`context`), all of them
  # (`blocks`), and one block's actual text (`text`).
  #
  # Ordering by cost lives here rather than in the tuner, deliberately. Content
  # facets already order their own way (blame by line, turns newest-first), and
  # cost must not touch confidence: confidence reports how strong the EVIDENCE is,
  # and an estimated cost model is not evidence about the block — it's a judgment
  # about importance. Same discipline as flags (bias the score, never the truth).

  # Shared cost formatting + the ranked read of a Transcript's blocks.
  module ContextRanking
    TOP = 10

    private

    # Blocks are reached through the graph, not re-read from disk: the provider
    # already minted them on expansion, so the facet just ranks what's there.
    def blocks_for(node, workspace)
      workspace.expand(node.id, now: Time.now)
      workspace.graph.edges_from(node.id)
               .select { |e| e.type == :CONSUMED }
               .filter_map { |e| workspace.graph.node(e.target_id) }
               .sort_by { |n| -n.properties[:cost].to_i }
    end

    def block_item(block, rank: nil)
      p = block.properties
      prefix = rank ? "#{rank.to_s.rjust(2)}. " : ""
      PanelItem.new(
        label: "#{prefix}#{p[:name]}",
        target_id: block.id,
        glyph: GLYPHS.fetch(p[:kind].to_s, "·"),
        detail: ["#{abbrev(p[:tokens])} tok × #{p[:resident]} turns resident ≈ #{abbrev(p[:cost])} cost-equiv"]
      )
    end

    GLYPHS = { "thinking" => "◇", "text" => "·", "tool_use" => "▸", "tool_result" => "↳" }.freeze

    def abbrev(count)
      count = count.to_i
      return "#{(count / 1_000_000.0).round(1)}M" if count >= 1_000_000
      return "#{(count / 1_000.0).round(1)}k" if count >= 1_000

      count.to_s
    end

    # The headline that reframes the number: the distinct material, the wire
    # volume, the re-read factor between them, and — the honest one — what it
    # actually COST. Measured across our 12 sessions: 98% of wire is cache reads
    # at 0.1x, so 685.4M of wire was worth 82.6M. Reporting wire alone invites
    # panic about a bill nobody paid; reporting cost alone hides the re-read
    # story. Both, or neither is true.
    def summary_lines(blocks)
      distinct = blocks.sum { |b| b.properties[:tokens].to_i }
      modelled = blocks.sum { |b| b.properties[:cost].to_i }
      wire = blocks.sum { |b| b.properties[:wire].to_i }
      factor = distinct.positive? ? (wire.to_f / distinct).round : 0
      ["#{abbrev(distinct)} distinct tokens in #{blocks.size} blocks · #{abbrev(wire)} wire " \
       "(~#{factor}× re-read) · ≈#{abbrev(modelled)} cost-equivalent",
       "cost ≈ size × turns resident — an early block is re-sent every turn after it lands.",
       "cache-weighted: a re-read bills at 0.1×, so wire volume overstates cost ~8×.",
       "ESTIMATES (bytes/4, no tokenizer); ranking is what they're for.",
       "top #{TOP} below; the `blocks` tab lists all #{blocks.size}."]
    end
  end

  # The top consumers: where the context actually went, ten rows deep.
  class ContextMode < Mode
    include ContextRanking

    def initialize(name: :context)
      super(name: name)
    end

    def applies?(node)
      node.type == :Transcript
    end

    def panel(node, workspace, now:)
      blocks = blocks_for(node, workspace)
      return empty_panel(node) if blocks.empty?

      top = blocks.first(TOP)
      items = top.each_with_index.map { |block, i| block_item(block, rank: i + 1) }
      # The cap is REPORTED, never silent (the search-cap convention): a view that
      # quietly shows 10 of 792 reads as "this is all of it". It rides the heading
      # because a section's lines render ABOVE its items — a "… 782 more" floating
      # over the list it caps reads as a header, not a footer.
      heading = "TOP #{top.size} OF #{blocks.size} CONSUMERS (estimated cost-equivalent)"
      Panel.new(node: node, mode: name, sections: [
                  PanelSection.new(heading: "CONTEXT", lines: summary_lines(blocks)),
                  PanelSection.new(heading: heading, items: items)
                ])
    end

    private

    def empty_panel(node)
      lines = ["(no transcript blocks — the file at #{node.properties[:path]} is missing or empty)"]
      Panel.new(node: node, mode: name, sections: [PanelSection.new(heading: "CONTEXT", lines: lines)])
    end
  end

  # The drill-down: every block, still cost-ranked. Bounded, and says so.
  class ContextBlocksMode < Mode
    include ContextRanking

    MAX = 500

    def initialize(name: :blocks)
      super(name: name)
    end

    def applies?(node)
      node.type == :Transcript
    end

    def panel(node, workspace, now:)
      blocks = blocks_for(node, workspace)
      shown = blocks.first(MAX)
      items = shown.each_with_index.map { |block, i| block_item(block, rank: i + 1) }
      lines = blocks.size > MAX ? ["… #{blocks.size - MAX} more below the top #{MAX} (bounded view)"] : []
      heading = "ALL BLOCKS (#{blocks.size}, by estimated cost-equivalent)"
      Panel.new(node: node, mode: name,
                sections: [PanelSection.new(heading: heading, items: items, lines: lines)])
    end
  end

  # One block's actual tokens — the thing the counts were counting.
  class ContextTextMode < Mode
    include ContextRanking

    MAX_LINES = 600

    def initialize(name: :text)
      super(name: name)
    end

    def applies?(node)
      node.type == :ContextBlock
    end

    def panel(node, _workspace, now:)
      p = node.properties
      body = Providers::Transcript.text_for(node, limit: MAX_LINES)
      header = ["#{p[:name]} — #{p[:kind]}, turn #{p[:turn]}",
                "#{abbrev(p[:tokens])} tok × #{p[:resident]} turns resident ≈ " \
                "#{abbrev(p[:cost])} cost-equivalent (#{abbrev(p[:wire])} wire)", ""]
      Panel.new(node: node, mode: name,
                sections: [PanelSection.new(heading: "TOKENS", lines: header + body)])
    end
  end
end
