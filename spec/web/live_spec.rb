# frozen_string_literal: true

# Live web: the Feed releases events as wall-clock elapses, pumped per request, so
# the browser's columns grow. Driven here by an injected clock for determinism —
# the same Feed/EventLog the TUI's `walk session --live` rides.
RSpec.describe "live web app" do
  AS = HColumns::Providers::AgentSession

  # a controllable wall clock: the test moves `wall` forward, the App reads it
  let(:base) { FIXED_NOW }
  let(:wall) { [base] }
  let(:clock) { -> { wall.first } }

  def advance(seconds)
    wall[0] = base + seconds
  end

  let(:feed) { AS.feed(now: base) }
  let(:graph) do
    g = HColumns::Graph.new
    feed.release(0.0, into: g) # seed: t0 (the task + who drives it)
    g
  end
  let(:workspace) { HColumns::Workspace.new(graph: graph) }
  let(:session) { HColumns::SessionContext.new(graph: graph, node_id: AS.session_id) }
  let(:app) do
    HColumns::Web::App.new(workspace: workspace, root_id: AS.session_id, now: base,
                           session: session, feed: feed, clock: clock)
  end

  it "is live, and a static app is not" do
    expect(app.live?).to be true
    static = HColumns::Web::App.new(workspace: workspace, root_id: AS.session_id, now: base)
    expect(static.live?).to be false
    expect(static.pump).to be false
    expect(static.done?).to be true
  end

  it "grows the session column as the clock advances" do
    items_at = lambda do
      app.pump
      app.panel(AS.session_id)[:sections].flat_map { |s| s[:items] }.map { |i| i[:label] }
    end

    advance(0.0)
    early = items_at.call
    version0 = app.version

    advance(2.0) # past PROPOSES (t=1.0) and the first touched files
    grown = items_at.call

    expect(app.version).to be > version0          # events were released
    expect(grown.size).to be > early.size          # the column grew under the walker
    expect(grown.join).to match(/diff:/)           # the ProposedChange appeared
  end

  it "follows the agent's phase: the session's auto mode flips over the timeline" do
    advance(0.0) # first app reference pins @start at base
    app.pump
    expect(app.panel(AS.session_id)[:mode]).to eq("default") # editing: diff floated but a Session can't render it

    advance(6.0) # past testing (t=4.0) and reviewing (t=5.5)
    app.pump
    expect(app.panel(AS.session_id)[:mode]).to eq("reviewer") # auto followed the phase to reviewing
  end

  it "reports done once the whole script has been released" do
    advance(0.0)
    app.pump
    expect(app.done?).to be false

    advance(60.0)
    app.pump
    expect(app.done?).to be true
  end

  describe HColumns::Web::Server do
    it "exposes /state with the live version and done flag, pumping on request" do
      server = HColumns::Web::Server.new(app)

      advance(0.0)
      _, type, body = server.respond("GET", "/state", {})
      expect(type).to eq("application/json")
      first = JSON.parse(body)
      expect(first).to include("version", "done")
      expect(first["done"]).to be false

      advance(2.0)
      after = JSON.parse(server.respond("GET", "/state", {}).last)
      expect(after["version"]).to be > first["version"] # the poll released new events
    end

    it "injects the live flag into the client shell" do
      live_html = HColumns::Web::Server.new(app).respond("GET", "/", {}).last
      expect(live_html).to include("const LIVE = true")

      static_app = HColumns::Web::App.new(workspace: workspace, root_id: AS.session_id, now: base)
      static_html = HColumns::Web::Server.new(static_app).respond("GET", "/", {}).last
      expect(static_html).to include("const LIVE = false")
    end
  end
end
