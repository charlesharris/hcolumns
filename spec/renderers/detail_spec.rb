# frozen_string_literal: true

RSpec.describe HColumns::Renderers::Detail do
  def now = FIXED_NOW

  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:lens) { HColumns::Lens.new(name: :default) }
  let(:orders_id) { HColumns::Providers::InMemoryFixture.orders_id }

  it "explains a node: identity, both edge directions, and the confidence math" do
    out = described_class.new.node(graph.node(orders_id), graph, lens: lens, now: now)

    expect(out).to include("NODE  src/orders.rb")
    expect(out).to include("identity    fs.path : local:/repo/src/orders.rb")
    expect(out).to include("HOW IT'S REACHED — incoming")
    expect(out).to include("WHAT IT RELATES TO — outgoing")

    # a deterministic edge is pinned; a probabilistic one shows the noisy-OR fold
    expect(out).to include("deterministic (verifiable ground truth, pinned to 1.0)")
    expect(out).to match(/noisy-OR  1 − ∏/)
    # per-observation reliability is broken down base × decay × mix (history, ~2d old)
    expect(out).to match(/base 0\.50 × decay 0\.9\d × mix 1/)
  end

  it "explains a column entry and how it got here" do
    workspace = HColumns::Workspace.new(graph: graph, lens: lens)
    entry = workspace.column_for(orders_id, now: now)
                     .groups.flat_map(&:entries).find { |e| e.relation == :CO_CHANGED_WITH }

    out = described_class.new.entry(entry, from: graph.node(orders_id), lens: lens, now: now)

    expect(out).to include("NODE  #{entry.target.name}")
    expect(out).to include("HOW IT GOT HERE")
    expect(out).to include("src/orders.rb —CO_CHANGED_WITH→ #{entry.target.name}")
    expect(out).to match(/score\s+[\d.]+ = \(conf/)
  end

  it "reflects the active lens's evidence-mix in the breakdown" do
    reviewer = HColumns::Lens.preset(:reviewer)
    out = described_class.new.node(graph.node(orders_id), graph, lens: reviewer, now: now)
    expect(out).to include("[lens: reviewer]")
  end
end
