# frozen_string_literal: true

# 1a: the mode/panel abstraction and the resolver, with nothing in the TUI yet.
RSpec.describe "modes and panels" do
  def now = FIXED_NOW

  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:workspace) { HColumns::Workspace.new(graph: graph) }
  let(:orders) { graph.node(HColumns::Providers::InMemoryFixture.orders_id) }
  let(:resolver) { HColumns::ModeResolver.new }

  describe HColumns::ModeResolver do
    it "ranks modes by node type, auto first, with details always available" do
      modes = resolver.modes_for(orders).map(&:name)
      expect(modes.first).to eq(:default)         # a SourceFile opens on the default (code) view
      expect(modes).to include(:details)          # the inspector is always a tab
      expect(resolver.auto(orders).name).to eq(modes.first)
    end

    it "opens a ProposedChange on the diff facet, with the lens column a tab away" do
      change = HColumns::Node.new(type: :ProposedChange, identity: { scheme: "agent.change", key: "x" })
      modes = resolver.modes_for(change).map(&:name)
      expect(modes.first).to eq(:diff)
      expect(modes).to include(:reviewer, :details)
    end

    it "falls back to a default tab set for unknown types" do
      odd = HColumns::Node.new(type: :Mystery, identity: { scheme: "x", key: "y" })
      expect(resolver.modes_for(odd).map(&:name)).to eq(%i[default details])
    end
  end

  describe HColumns::LensMode do
    it "renders a node's lensed column as a panel of sections and focusable items" do
      panel = HColumns::Mode[:default].panel(orders, workspace, now: now)

      column = workspace.column_for(orders.id, now: now) # the equivalent column built the old way
      expect(panel.sections.map(&:heading)).to eq(column.groups.map { |g| g.relation.to_s })
      expect(panel.items.map(&:target_id)).to eq(column.entries.map { |e| e.target.id })
      expect(panel.items.map(&:confidence)).to eq(column.entries.map(&:confidence))
    end

    it "is a cheap re-view: a different lens reorders the same node without re-pull" do
      default_order = HColumns::Mode[:default].panel(orders, workspace, now: now).items.map(&:target_id)
      git_order = HColumns::Mode[:git].panel(orders, workspace, now: now).items.map(&:target_id)
      expect(git_order).to match_array(default_order) # same evidence...
      # ...the git lens lifts history/authorship, so the ranking differs
      expect(git_order).not_to eq(default_order)
    end
  end

  describe HColumns::DetailFacet do
    it "is a facet whose items are the node's edges, each carrying its breakdown" do
      panel = HColumns::Mode[:details].panel(orders, workspace, now: now)

      expect(panel.sections.first.heading).to eq("NODE")
      expect(panel.sections.first.lines.join).to include("src/orders.rb")

      headings = panel.sections.map(&:heading)
      expect(headings.any? { |h| h.start_with?("how it's reached") }).to be true
      expect(headings.any? { |h| h.start_with?("what it relates to") }).to be true

      # every edge is focusable (descend-able) and carries the confidence math
      item = panel.items.find { |i| i.label.include?("CO_CHANGED_WITH") }
      expect(item.target_id).not_to be_nil
      expect(item.detail.join("\n")).to match(/noisy-OR|deterministic/)
    end

    it "lets a details item descend to the other end of the relation" do
      panel = HColumns::Mode[:details].panel(orders, workspace, now: now)
      outgoing = panel.items.find { |i| i.label.start_with?("src/orders.rb —CO_CHANGED_WITH") }
      expect(graph.node(outgoing.target_id)).not_to be_nil # a real node to walk into
    end
  end

  describe HColumns::DiffFacet do
    let(:session_graph) { HColumns::Providers::AgentSession.build(now: now) }
    let(:session_ws) { HColumns::Workspace.new(graph: session_graph) }
    let(:change) { session_graph.node(HColumns::Identity.id_for(scheme: "agent.change", key: "s1:c1")) }

    it "presents a ProposedChange as a changeset, not a relation column" do
      panel = HColumns::Mode[:diff].panel(change, session_ws, now: now)

      labels = panel.items.map(&:label)
      expect(labels.size).to eq(4)                              # the touched files, as focusable items
      expect(labels.any? { |l| l.include?("★") }).to be true   # the focus file starred
      expect(labels.any? { |l| l.include?("+221") }).to be true # churn shown

      lines = panel.sections.flat_map(&:lines).join(" ")
      expect(lines).to include("file(s) changed")
      expect(lines).to include("✓")                            # the verification status line

      expect(panel.items.map(&:target_id)).to all(satisfy { |id| session_graph.node(id) }) # each descendable
    end

    it "carries each file's hunk as item detail (what the preview pane shows)" do
      panel = HColumns::Mode[:diff].panel(change, session_ws, now: now)
      hunked = panel.items.find { |i| i.detail.join("\n").include?("module AgentSession") }
      expect(hunked).not_to be_nil
      expect(hunked.detail.first).to include("agent_session.rb") # a header line, then the hunk
    end
  end
end
