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

  describe "Refreshing (re-projection on a moved world)" do
    def counting_source(world, interval: 0)
      builds = 0
      build = lambda do
        builds += 1
        HColumns::Web::App.new(workspace: HColumns::Workspace.new(graph: graph),
                               root_id: orders_id, now: now)
      end
      source = described_class::Refreshing.new(build, probe: -> { world[:fingerprint] },
                                                      interval: interval)
      [source, -> { builds }]
    end

    it "keeps serving the same warm app while the world holds still" do
      source, builds = counting_source({ fingerprint: "a" })
      app = source.checkout
      3.times { app.pump }
      expect(builds.call).to eq(1)
      expect(app.panel(orders_id)).to include(:node)
    end

    it "re-projects on a changed fingerprint and bumps version past the swap" do
      world = { fingerprint: "a" }
      source, builds = counting_source(world)
      app = source.checkout
      app.pump
      before = app.version

      world[:fingerprint] = "b"
      app.pump
      expect(builds.call).to eq(2)
      expect(app.version).to be > before # generation term: same log count, new projection
      expect(app.panel(orders_id)).to include(:node) # the fresh app answers
    end

    it "throttles the probe: a long interval means one look, not one per pump" do
      looks = 0
      build = lambda do
        HColumns::Web::App.new(workspace: HColumns::Workspace.new(graph: graph),
                               root_id: orders_id, now: now)
      end
      probe = lambda do
        looks += 1
        "steady"
      end
      app = described_class::Refreshing.new(build, probe: probe, interval: 3600).checkout
      5.times { app.pump }
      expect(looks).to eq(1) # the constructor's initial look only
    end
  end

  it "any checkout-duck plugs into the Server (the strategy is constructor-time)" do
    server = HColumns::Web::Server.new(apps: described_class::Locked.new(fresh_app))
    _, _, body = server.respond("GET", "/panel", { "id" => orders_id })
    expect(JSON.parse(body)["node"]["id"]).to eq(orders_id)
  end
end
