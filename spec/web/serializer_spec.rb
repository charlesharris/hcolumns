# frozen_string_literal: true

# The web "renderer": same Panel/Node data the terminal renderers consume, out as
# plain JSON-able Hashes. These specs pin the cross-front-end contract — what a
# browser client can rely on being in the payload.
RSpec.describe HColumns::Web::Serializer do
  def now = FIXED_NOW

  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:workspace) { HColumns::Workspace.new(graph: graph) }
  let(:orders) { graph.node(HColumns::Providers::InMemoryFixture.orders_id) }
  let(:resolver) { HColumns::ModeResolver.new }

  def serialize(node, mode: :default)
    modes = resolver.modes_for(node)
    panel = HColumns::Mode[mode].panel(node, workspace, now: now)
    described_class.panel(panel, modes: modes.map(&:name))
  end

  it "carries the node, the active mode, and the ranked tab list" do
    out = serialize(orders)

    expect(out[:node][:type]).to eq("SourceFile")
    expect(out[:node][:name]).to include("src/orders.rb")
    expect(out[:mode]).to eq("default")
    expect(out[:modes]).to be_an(Array).and include("default", "details")
  end

  it "serializes each section's heading, lines, and focusable items" do
    section = serialize(orders)[:sections].find { |s| s[:items].any? }

    expect(section[:heading]).to be_a(String)
    item = section[:items].first
    expect(item).to include(:label, :target_id, :confidence, :glyph, :detail)
    expect(item[:target_id]).to be_a(String) # the descend target — a real node id
    expect(item[:label]).to be_a(String)
  end

  it "is JSON round-trippable — symbols and nested hashes flattened to strings" do
    out = serialize(orders)
    reparsed = JSON.parse(JSON.generate(out))

    expect(reparsed["node"]["type"]).to eq("SourceFile")
    expect(reparsed["modes"]).to include("default")
    # the whole structure survives a JSON round-trip with no Ruby-only values
    expect { JSON.generate(out) }.not_to raise_error
  end

  it "keeps symbol-keyed nested properties JSON-friendly without flattening shape" do
    # a ProposedChange carries :hunks => { path => [lines] }: symbols + nesting
    session_graph = HColumns::Providers::AgentSession.build(now: now)
    change = session_graph.node(HColumns::Identity.id_for(scheme: "agent.change", key: "s1:c1"))
    props = described_class.node(change)[:properties]

    expect(props.keys).to all(be_a(String))             # symbol keys stringified
    expect(JSON.parse(JSON.generate(props))).to eq(props) # already JSON-friendly, round-trips intact
    expect(props["hunks"]).to be_a(Hash)                 # nesting preserved, not flattened
  end
end
