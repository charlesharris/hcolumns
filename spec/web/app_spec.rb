# frozen_string_literal: true

# The App is the consumer the Serializer was missing: a node id in, the panel JSON
# out, using the same ModeResolver the TUI drives. These specs pin that the browser
# and the terminal agree on tabs/auto, and that descending works on one stateful
# Workspace (the cascade-as-you-go property).
RSpec.describe HColumns::Web::App do
  def now = FIXED_NOW

  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:workspace) { HColumns::Workspace.new(graph: graph) }
  let(:orders_id) { HColumns::Providers::InMemoryFixture.orders_id }
  let(:app) { described_class.new(workspace: workspace, root_id: orders_id, now: now) }

  it "returns the root node's panel with the resolver's ranked modes" do
    out = app.root

    expect(out[:node][:id]).to eq(orders_id)
    expect(out[:mode]).to eq("default")                  # the auto mode = head of the ranked list
    expect(out[:modes]).to eq(HColumns::ModeResolver.new.modes_for(graph.node(orders_id)).map { |m| m.name.to_s })
  end

  it "selects a non-auto tab by mode key, falling back to auto on an unknown key" do
    expect(app.panel(orders_id, mode: "details")[:mode]).to eq("details")
    expect(app.panel(orders_id, mode: "nonsense")[:mode]).to eq("default") # graceful fallback, never nil
  end

  it "returns nil for an unknown node id (the server turns this into a 404)" do
    expect(app.panel("obj:doesnotexist")).to be_nil
  end

  it "lets a client descend: an item's target_id is itself a fetchable panel" do
    root = app.root
    target = root[:sections].flat_map { |s| s[:items] }.first[:target_id]

    descended = app.panel(target)
    expect(descended).not_to be_nil
    expect(descended[:node][:id]).to eq(target) # lazy expand on the shared workspace made it real
  end

  it "follows the session phase so the browser's auto mode matches the agent's work" do
    session_graph = HColumns::Providers::AgentSession.build(now: now)
    session_ws = HColumns::Workspace.new(graph: session_graph)
    session_id = HColumns::Providers::AgentSession.session_id
    ctx = HColumns::SessionContext.new(graph: session_graph, node_id: session_id)
    phased = described_class.new(workspace: session_ws, root_id: session_id, now: now, session: ctx)

    # the resolver is consulted with the session, so the tab order is the phased one
    expected = HColumns::ModeResolver.new.modes_for(session_graph.node(session_id), session: ctx).map { |m| m.name.to_s }
    expect(phased.root[:modes]).to eq(expected)
  end
end
