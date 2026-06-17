# frozen_string_literal: true

RSpec.describe HColumns::Renderers::CascadeText do
  def now = FIXED_NOW

  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:repo) { graph.nodes.find { |n| n.name == "repo/" }.id }
  subject(:renderer) { described_class.new(color: false) }

  # repo › src › orders.rb (+ a preview) — enough panels to force clipping when narrow.
  def cascade
    c = HColumns::Cascade.new(HColumns::Workspace.new(graph: graph), repo, now: now)
    c.active.cursor = c.active_entries.index { |e| e.label == "src" }
    c.into
    c.active.cursor = c.active_entries.index { |e| e.label == "src/orders.rb" }
    c.into
    c
  end

  def render(width: nil, height: nil)
    renderer.render(cascade, width: width, height: height)
  end

  it "never emits a line wider than the viewport, at any width" do
    [30, 44, 60, 80, 120].each do |w|
      widest = render(width: w).split("\n").map(&:length).max
      expect(widest).to be <= w, "width #{w}: widest line was #{widest}"
    end
  end

  it "clips to the rightmost columns when they don't all fit, keeping the full trail" do
    crumb = render(width: 44).split("\n").first
    expect(crumb).to include("‹")          # marks that columns scrolled off the left
    expect(crumb).to include("repo/")      # ...but the whole route is still in the breadcrumb
    expect(crumb).to include("orders.rb")  # the active node
  end

  it "shows every column when they all fit (no clip marker)" do
    expect(render(width: 200).split("\n").first).not_to include("‹")
  end

  it "grows columns to use a roomy terminal, up to the cap" do
    narrow = render(width: 80).split("\n").map(&:length).max
    wide   = render(width: 200).split("\n").map(&:length).max
    expect(wide).to be > narrow
  end

  it "clamps rendered height to the viewport" do
    [8, 10, 14].each do |h|
      expect(render(width: 80, height: h).split("\n").length).to be <= h
    end
  end

  it "marks vertical overflow when a column is taller than the viewport" do
    expect(render(width: 80, height: 8)).to include("↓ +")
  end

  it "renders the selected item's detail full-width in the bottom dock" do
    change_id = HColumns::Identity.id_for(scheme: "agent.change", key: "s1:c1")
    session = HColumns::Providers::AgentSession.build(now: now)
    cascade = HColumns::Cascade.new(HColumns::Workspace.new(graph: session), change_id, now: now)

    out = renderer.render(cascade, width: 100, height: 24) # opens on the diff facet, cursor on a file
    expect(out).to match(/─{90,}/)                # the dock separator spans the width
    expect(out).to include("module AgentSession") # the hunk body, not clipped to a column
  end

  it "renders unconstrained (no width/height) as before — the golden form" do
    out = render
    expect(out).to include("repo/")
    expect(out).to include("│")
    expect(out).not_to include("‹") # nothing clipped without a width budget
  end
end
