# frozen_string_literal: true

require "tmpdir"

# Node flags: the user's up/down/exclude/clear judgment as a first-class event.
# The load-bearing property throughout: a flag is a BIAS at the lens/score layer
# — it reorders and hides, but never mutates an edge's confidence (evidence
# stays truth; the lens holds opinion, and the rank reason shows the ⚑).
RSpec.describe "node flags" do
  def now = FIXED_NOW

  def node(key, type: :SourceFile)
    HColumns::Node.new(type: type, identity: { scheme: "spec", key: key }, properties: { name: key })
  end

  def observe(graph, from, to, kind: :structure)
    graph.observe(HColumns::Observation.new(
                    provider: :spec, subject_id: from.id, target_id: to.id, edge_type: :CONTAINS,
                    weight: 1.0, evidence_kind: kind, observed_at: now, evidence_summary: "spec"
                  ))
  end

  # A root with three equally-evidenced children — ties broken alphabetically,
  # so any reordering below is the flag's doing alone.
  def build_graph(log: nil)
    graph = HColumns::Graph.new(log: log)
    root = graph.add_node(node("root", type: :Directory))
    children = %w[alpha beta gamma].map { |k| graph.add_node(node(k)) }
    children.each { |c| observe(graph, root, c) }
    [graph, root, children]
  end

  def column_names(graph, root)
    HColumns::ColumnBuilder.new(graph).build(root.id, now: now)
                           .entries.map { |e| e.target.name }
  end

  describe "the graph fold" do
    it "folds a flag, last flag wins, clear removes" do
      graph, = build_graph
      graph.flag(node_id: "n1", level: :down, by: "charris", at: now)
      expect(graph.flag_of("n1")).to eq(:down)

      graph.flag(node_id: "n1", level: :up, at: now)
      expect(graph.flag_of("n1")).to eq(:up)

      graph.flag(node_id: "n1", level: :clear, at: now)
      expect(graph.flag_of("n1")).to be_nil
    end

    it "rejects an unknown level" do
      expect { HColumns::Graph.new.flag(node_id: "n", level: :nuke) }.to raise_error(ArgumentError, /nuke/)
    end

    it "records flags as events on a log-backed graph, and replay reproduces them" do
      log = HColumns::EventLog.new
      graph, root, = build_graph(log: log)
      target = graph.nodes.find { |n| n.name == "beta" }
      graph.flag(node_id: target.id, level: :down, by: "charris", at: now)

      expect(log.events.map(&:kind)).to include(:flag)
      projection = log.project # replay from scratch
      expect(projection.flag_of(target.id)).to eq(:down)
      expect(column_names(projection, root).last).to eq("beta")
    end
  end

  describe "ranking bias (never confidence)" do
    it "downrank sinks an entry, uprank floats one, and confidence is untouched" do
      graph, root, children = build_graph
      expect(column_names(graph, root)).to eq(%w[alpha beta gamma])

      graph.flag(node_id: children[0].id, level: :down, by: "charris", at: now)
      graph.flag(node_id: children[2].id, level: :up, at: now)
      expect(column_names(graph, root)).to eq(%w[gamma beta alpha])

      entries = HColumns::ColumnBuilder.new(graph).build(root.id, now: now).entries
      expect(entries.map(&:confidence)).to all(eq(1.0)) # truth unmoved
      alpha = entries.find { |e| e.target.name == "alpha" }
      expect(alpha.rank_reason).to include("⚑down (charris)") # the bias is visible
    end

    it "exclude hides the entry from lens columns but not from the details facet" do
      graph, root, children = build_graph
      graph.flag(node_id: children[1].id, level: :exclude, at: now)
      expect(column_names(graph, root)).to eq(%w[alpha gamma])

      # The inspector still shows the edge — exclusion is opinion, not deletion.
      ws = HColumns::Workspace.new(graph: graph)
      details = HColumns::Mode[:details].panel(root, ws, now: now)
      expect(details.items.map(&:label).join).to include("beta")
    end

    it "clear restores the original order" do
      graph, root, children = build_graph
      graph.flag(node_id: children[0].id, level: :down, at: now)
      graph.flag(node_id: children[0].id, level: :clear, at: now)
      expect(column_names(graph, root)).to eq(%w[alpha beta gamma])
    end
  end

  describe "persistence (the accreting flag store)" do
    it "round-trips a flag event through the JSONL codec, types intact" do
      line = HColumns::Persistence.line_for(
        kind: :flag, payload: { node_id: "n1", level: :down, by: "charris", at: now }, at: now
      )
      parsed = HColumns::Persistence.parse_line(line)
      expect(parsed[:kind]).to eq(:flag)
      expect(parsed[:payload][:level]).to eq(:down) # Symbol survived
      expect(parsed[:payload][:at]).to eq(now)      # Time survived, exactly
    end

    it "appends as flags happen and replays into the next session's graph" do
      Dir.mktmpdir do |dir|
        store = HColumns::FlagStore.new(File.join(dir, ".hcolumns", "flags.jsonl"))

        graph, root, children = build_graph
        ws = HColumns::Workspace.new(graph: graph, flag_store: store)
        ws.flag(children[1].id, :exclude, at: now, by: "charris")
        ws.flag(children[0].id, :down, at: now, by: "charris")
        ws.flag(children[0].id, :clear, at: now, by: "charris") # supersedes the :down

        graph2, root2, = build_graph # "tomorrow's" fresh session
        ws2 = HColumns::Workspace.new(graph: graph2, flag_store: store)
        expect(ws2.replay_flags).to eq(3) # every event replays; the fold settles it
        expect(column_names(graph2, root2)).to eq(%w[alpha gamma])
      end
    end
  end

  describe "the cascade action (what the TUI/web keys drive)" do
    it "flags the selected item's target and re-ranks the open column in place" do
      graph, root, = build_graph
      ws = HColumns::Workspace.new(graph: graph)
      cascade = HColumns::Cascade.new(ws, root.id, now: now)

      expect(cascade.selected_entry.label).to eq("alpha")
      cascade.flag_selected(:down)
      expect(cascade.active_entries.map(&:label)).to eq(%w[beta gamma alpha])

      cascade.flag_selected(:exclude) # now pointing at beta
      expect(cascade.active_entries.map(&:label)).to eq(%w[gamma alpha])
    end
  end

  describe "the web route" do
    it "flags via /flag and rejects unknown levels" do
      graph, root, children = build_graph
      ws = HColumns::Workspace.new(graph: graph)
      app = HColumns::Web::App.new(workspace: ws, root_id: root.id, now: now)
      server = HColumns::Web::Server.new(app)

      status, _type, _body = server.respond("GET", "/flag", { "id" => children[0].id, "level" => "down" })
      expect(status).to eq(200)
      expect(graph.flag_of(children[0].id)).to eq(:down)

      status, = server.respond("GET", "/flag", { "id" => children[0].id, "level" => "nuke" })
      expect(status).to eq(404)
      status, = server.respond("GET", "/flag", { "id" => "obj:nope", "level" => "down" })
      expect(status).to eq(404)
    end
  end
end
