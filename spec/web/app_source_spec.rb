# frozen_string_literal: true

# The concurrency seam: the Server only ever asks its AppSource to `checkout`,
# so the sharing strategy (one app, fresh-per-connection, or a future locked
# shared one) is a constructor-time choice that never touches routing code.
RSpec.describe HColumns::Web::AppSource do
  def now = FIXED_NOW

  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:orders_id) { HColumns::Providers::InMemoryFixture.orders_id }

  def fresh_app
    HColumns::Web::App.new(workspace: HColumns::Workspace.new(graph: graph),
                           root_id: orders_id, now: now)
  end

  it "Single hands every checkout the same app (the single-threaded server)" do
    source = described_class::Single.new(app = fresh_app)
    expect(source.checkout).to be(app)
    expect(source.checkout).to be(app)
  end

  it "PerConnection builds a fresh app per checkout (share-nothing)" do
    source = described_class::PerConnection.new(-> { fresh_app })
    expect(source.checkout).not_to be(source.checkout)
  end

  it "Locked hands every checkout the same decorator over one warm app" do
    source = described_class::Locked.new(fresh_app)
    expect(source.checkout).to be(source.checkout)
  end

  it "Locked keeps the whole App API answering through the mutex" do
    app = described_class::Locked.new(fresh_app).checkout
    expect(app.root_id).to eq(orders_id)
    expect(app.live?).to be(false)
    expect(app.panel(orders_id, mode: "details")[:mode]).to eq("details")
  end

  it "Locked serializes concurrent panel builds without error (threaded server)" do
    app = described_class::Locked.new(fresh_app).checkout
    panels = Array.new(8) { Thread.new { app.panel(orders_id) } }.map(&:value)
    expect(panels).to all(include(:node))
  end

  it "any checkout-duck plugs into the Server (the strategy is constructor-time)" do
    server = HColumns::Web::Server.new(apps: described_class::Locked.new(fresh_app))
    _, _, body = server.respond("GET", "/panel", { "id" => orders_id })
    expect(JSON.parse(body)["node"]["id"]).to eq(orders_id)
  end
end
