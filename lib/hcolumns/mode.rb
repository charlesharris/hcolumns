# frozen_string_literal: true

module HColumns
  # A mode is a *facet of a node* — one way of viewing it, materialized as a Panel.
  # The cheap kind re-lenses the standard column (LensMode); the richer kind is a
  # different representation entirely (DetailFacet now; diff/debug facets later).
  # Tabs on a column are the modes a ModeResolver ranks for that node; the head is
  # the auto mode. A mode is stateless — it builds a Panel for (node, workspace).
  class Mode
    attr_reader :name

    def initialize(name:)
      @name = name.to_sym
    end

    def label
      name.to_s
    end

    # Whether this mode is meaningful for `node` — so a phase can promote a mode
    # without forcing it onto nodes it can't render. Lens/detail modes apply to
    # anything; a facet that reads specific edges narrows this.
    def applies?(_node)
      true
    end

    def panel(_node, _workspace, now:)
      raise NotImplementedError
    end

    # --- registry: mode key -> instance ---------------------------------------
    # Lens modes are derived from the lens registry (one per preset), plus the
    # standalone facets. Adding a facet = register it here (or from its own file).
    class << self
      def registry
        @registry ||= build_registry
      end

      def [](name)
        registry.fetch(name.to_sym) { raise ArgumentError, "unknown mode: #{name.inspect}" }
      end

      def names
        registry.keys
      end

      private

      def build_registry
        modes = {}
        Lens.names.each { |lens_name| modes[lens_name] = LensMode.new(name: lens_name, lens: Lens.preset(lens_name)) }
        modes[:details] = DetailFacet.new
        modes[:diff] = DiffFacet.new
        modes[:source] = SourceMode.new   # a file's text
        modes[:blame] = BlameMode.new     # a file's per-line commit history
        modes[:gitdiff] = GitDiffMode.new # a commit's (or a file's, scoped) diff
        modes[:commitsource] = CommitSourceMode.new # a CommitFile's blob at that commit
        modes[:output] = OutputMode.new   # a test run / log line's captured output
        modes[:bead] = BeadMode.new       # a bead's body (description/design/notes)
        modes
      end
    end
  end

  # A mode backed by a lens: the panel is the lensed column, with each relation
  # group a section and each entry a focusable item — i.e. exactly today's column,
  # now expressible as one facet among several.
  class LensMode < Mode
    def initialize(name:, lens:)
      super(name: name)
      @lens = lens
    end

    attr_reader :lens

    def panel(node, workspace, now:)
      workspace.expand(node.id, now: now)
      column = ColumnBuilder.new(workspace.graph, lens: @lens).build(node.id, now: now)

      sections = column.groups.map do |group|
        items = group.entries.map do |entry|
          PanelItem.new(label: entry.target.name, target_id: entry.target.id,
                        maturity: entry.maturity, confidence: entry.confidence, reason: entry.rank_reason)
        end
        PanelSection.new(heading: group.relation.to_s, items: items)
      end
      Panel.new(node: node, mode: name, sections: sections)
    end
  end

  # The inspector as a facet: an identity block (display lines), then the node's
  # incoming and outgoing edges as focusable items — each carrying its confidence
  # breakdown as `detail`. Descending an incoming item walks back to where the
  # relation came from; an outgoing item walks to its target. Reuses the same
  # Renderers::Detail building blocks the CLI `inspect` uses.
  class DetailFacet < Mode
    def initialize(name: :details, renderer: Renderers::Detail.new)
      super(name: name)
      @renderer = renderer
    end

    def panel(node, workspace, now:)
      workspace.expand(node.id, now: now)
      graph = workspace.graph
      lens = workspace.respond_to?(:lens) && workspace.lens ? workspace.lens : Lens.new

      identity = PanelSection.new(heading: "NODE", lines: @renderer.node_block(node))
      incoming = edge_section("how it's reached — incoming", graph.edges_into(node.id), graph, lens, now,
                              focus: :subject_id, this: node.name)
      outgoing = edge_section("what it relates to — outgoing", graph.edges_from(node.id), graph, lens, now,
                              focus: :target_id, this: node.name)
      Panel.new(node: node, mode: name, sections: [identity, incoming, outgoing])
    end

    private

    def edge_section(heading, edges, graph, lens, now, focus:, this:)
      items = edges.map do |edge|
        other = graph.node(focus == :subject_id ? edge.subject_id : edge.target_id)
        from_name = focus == :subject_id ? name_of(other) : this
        target_name = focus == :subject_id ? this : name_of(other)
        PanelItem.new(
          label: "#{from_name} —#{edge.type}→ #{target_name}",
          target_id: edge.public_send(focus),
          maturity: edge.maturity(now: now),
          confidence: lens.confidence(edge, now: now),
          reason: "[#{edge.evidence_kinds.map(&:to_s).join('+')}]",
          detail: @renderer.edge_block(edge, lens: lens, now: now, from_name: from_name, target_name: target_name)
        )
      end
      PanelSection.new(heading: "#{heading} (#{items.size})", items: items)
    end

    def name_of(node)
      node ? node.name : "?"
    end
  end

  # The first *renderer-carrying* facet: a ProposedChange as a changeset, not a
  # relation column. It reads the same TOUCHES / FOCUSES_ON / VERIFIED_BY edges
  # but presents them as a diff — files with churn, the focus file starred, a
  # verification status line — and each file stays focusable (descend into it).
  # This is "facets are the thing": same evidence, a genuinely different view.
  class DiffFacet < Mode
    def initialize(name: :diff)
      super(name: name)
    end

    def applies?(node)
      node.type == :ProposedChange
    end

    def panel(node, workspace, now:)
      workspace.expand(node.id, now: now)
      graph = workspace.graph
      out = graph.edges_from(node.id)
      touches = out.select { |e| e.type == :TOUCHES }
      focus = out.select { |e| e.type == :FOCUSES_ON }.map(&:target_id)
      verified = out.find { |e| e.type == :VERIFIED_BY }
      hunks = node.properties[:hunks] || {}

      header = PanelSection.new(lines: ["#{touches.size} file(s) changed", ""])
      files = PanelSection.new(items: touches.map { |e| file_item(e, graph, focus, now, hunks) })
      status = verified ? "✓ #{name_of(graph.node(verified.target_id))}" : "• not verified"
      footer = PanelSection.new(lines: ["", status])

      Panel.new(node: node, mode: name, sections: [header, files, footer])
    end

    private

    def file_item(edge, graph, focus, now, hunks)
      file = graph.node(edge.target_id)
      path = file ? file.name.to_s : "?"
      churn = churn_of(edge)
      starred = focus.include?(edge.target_id)
      star = starred ? "  ★" : ""
      PanelItem.new(label: "#{basename(file)}#{churn}#{star}", target_id: edge.target_id, glyph: "~",
                    maturity: edge.maturity(now: now), confidence: edge.confidence(now: now),
                    reason: churn.strip, detail: file_detail(path, churn, starred, hunks))
    end

    # The per-file view shown in the preview pane: a header, then the hunk if the
    # change carries one (real content lands here once an agent emits real diffs).
    def file_detail(path, churn, starred, hunks)
      header = "#{path}#{churn}#{starred ? '   ★ focus' : ''}"
      body = hunks[path] || ["(no hunk recorded for this change)"]
      [header, ""] + body
    end

    def churn_of(edge)
      summary = edge.observations.map(&:evidence_summary).compact.first.to_s
      summary =~ /\(([^)]+)\)/ ? "  #{Regexp.last_match(1)}" : ""
    end

    def basename(node)
      node ? node.name.to_s.split("/").last : "?"
    end

    def name_of(node)
      node ? node.name : "?"
    end
  end
end
