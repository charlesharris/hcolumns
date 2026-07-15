# frozen_string_literal: true

require "tmpdir"

# The real agent bridge (hc-gzj): a neutral vocabulary -> Persistence events on an
# append-only log. These specs drive the vocabulary and read the log back through
# the same Persistence.load + project the live walk/serve uses, so what a bridged
# session projects is exactly what a browser would show growing.
RSpec.describe HColumns::AgentBridge do
  def now = FIXED_NOW

  around do |example|
    Dir.mktmpdir("hcol-bridge") do |dir|
      @dir = dir
      @log = File.join(dir, "live.jsonl")
      example.run
    end
  end

  # A fresh bridge instance per call models a fresh hook process (no shared memory).
  def bridge(session: "s1")
    described_class.new(path: @log, session: session, clock: -> { now })
  end

  def graph
    File.open(@log) { |io| HColumns::Persistence.load(io) }.project
  end

  def edge(from_type, relation)
    subject = graph.nodes.find { |n| n.type == from_type }
    graph.edges_from(subject.id).find { |e| e.type == relation }
  end

  it "writes the session spine as a header on the first command" do
    bridge.apply("edit lib/foo.rb")
    g = graph
    expect(g.nodes.map(&:type)).to include(:Session, :Agent, :ProposedChange)
    expect(edge(:Session, :DRIVEN_BY)).not_to be_nil
    expect(edge(:Session, :PROPOSES)).not_to be_nil
  end

  it "turns `edit` into a ProposedChange TOUCHES onto a real fs.path node (unifies)" do
    bridge.apply("edit lib/foo.rb")
    touches = edge(:ProposedChange, :TOUCHES)
    file = graph.node(touches.target_id)
    expect(file.identity[:scheme]).to eq("fs.path") # same identity the fs/git/beads providers use
    expect(file.properties[:path]).to eq(File.expand_path("lib/foo.rb"))
    expect(touches.confidence(now: now)).to eq(1.0) # a real edit is verifiable ground truth
  end

  it "drives the session phase (a Symbol that survives replay and reaches the resolver)" do
    b = bridge
    b.apply("edit lib/foo.rb")
    b.apply("phase reviewing")
    g = graph
    session = g.nodes.find { |n| n.type == :Session }
    expect(session.properties[:phase]).to eq(:reviewing)
    ctx = HColumns::SessionContext.new(graph: g, node_id: session.id)
    expect(HColumns::ModeResolver.new.auto(session, session: ctx).name).to eq(:reviewer)
  end

  it "records a test run as VERIFIED_BY, carrying pass/fail" do
    b = bridge
    b.apply("edit lib/foo.rb")
    b.apply("test fail bundle exec rspec")
    verified = edge(:ProposedChange, :VERIFIED_BY)
    run = graph.node(verified.target_id)
    expect(run.type).to eq(:TestRun)
    expect(run.properties[:output].join).to include("FAIL").and include("rspec")
  end

  it "writes the header only once across separate hook processes" do
    bridge.apply("edit a.rb")        # process 1: header + edit
    bridge.apply("edit b.rb")        # process 2: no second header, just the edit
    bridge.apply("edit c.rb")        # process 3
    expect(graph.nodes.count { |n| n.type == :Session }).to eq(1)
    expect(graph.nodes.count { |n| n.type == :ProposedChange }).to eq(1)
    expect(graph.edges_from(graph.nodes.find { |n| n.type == :ProposedChange }.id)
                .count { |e| e.type == :TOUCHES }).to eq(3)
  end

  it "adopts a named spine from the log, so later processes' edges reference it" do
    bridge.apply("session dogfood Dogfooding the bridge") # process 1 names the session
    bridge(session: "live").apply("edit lib/foo.rb")      # process 2 wakes with the default key
    bridge(session: "live").apply("phase testing")        # process 3 re-emits the Session node

    g = graph
    sessions = g.nodes.select { |n| n.type == :Session }
    expect(sessions.map { |n| n.identity[:key] }).to eq(["dogfood"]) # no ghost "live" twin
    expect(sessions.first.properties[:name]).to eq("Task: Dogfooding the bridge") # title survives re-emit
    expect(sessions.first.properties[:phase]).to eq(:testing)
    change = g.nodes.find { |n| n.type == :ProposedChange }
    expect(change.identity[:key]).to eq("dogfood:c1")
    touches = g.edges_from(change.id).find { |e| e.type == :TOUCHES }
    expect(touches).not_to be_nil # the edit hangs off the spine on disk, not a never-emitted node
  end

  it "`session` names the spine and `done` closes the stream" do
    b = bridge(session: "live")
    b.apply("session feature-x Add the widget")
    b.apply("done")
    session = graph.nodes.find { |n| n.type == :Session }
    expect(session.identity[:key]).to eq("feature-x")
    expect(session.properties[:name]).to eq("Task: Add the widget")
    # the eof marker is present but Persistence.load skips it (a live log is a snapshot)
    expect(File.read(@log)).to include('"eof":true')
  end

  it "partitions the log with `turn` markers; fold assigns ordinals across processes" do
    bridge.apply("turn first ask")        # process 1 (header lands before the marker)
    bridge.apply("edit lib/foo.rb")       # process 2
    bridge.apply("turn second ask")       # process 3 — no numbering by the producer
    bridge.apply("edit lib/bar.rb")       # process 4
    g = graph
    expect(g.turns.map { |t| [t[:index], t[:label]] }).to eq([[1, "first ask"], [2, "second ask"]])
    change = g.nodes.find { |n| n.type == :ProposedChange }
    stamped = g.edges_from(change.id).select { |e| e.type == :TOUCHES }
                .to_h { |e| [g.node(e.target_id).properties[:name], e.observations.first.turn[:index]] }
    expect(stamped).to eq({ "foo.rb" => 1, "bar.rb" => 2 })
    # the header spine (written before the first marker) stays unattributed
    driven = g.edges_from(g.nodes.find { |n| n.type == :Session }.id).find { |e| e.type == :DRIVEN_BY }
    expect(driven.observations.first.turn).to be_nil
  end

  it "attaches `usage` totals to the open turn across processes, last word wins" do
    bridge.apply("turn first ask")                       # process 1
    bridge.apply("usage in=100 out=5")                   # process 2 (mid-turn tick)
    bridge.apply("usage in=4200 out=320 cache_read=39000") # process 3 (turn end totals)
    expect(graph.turns.last[:tokens]).to eq({ in: 4200, out: 320, cache_read: 39_000 })
  end

  it "ignores a `usage` line with nothing parseable (a noisy hook never crashes)" do
    b = bridge
    b.apply("turn ask")
    b.apply("usage lots of tokens probably")
    expect(graph.turns.last[:tokens]).to be_nil
  end

  describe "test lifecycle (start → ok/fail re-emits the same node)" do
    it "shows a running test that flips in place when the result lands" do
      bridge.apply("test start bundle exec rspec")   # process 1: in flight
      g = graph
      run = g.nodes.find { |n| n.type == :TestRun }
      expect(run.properties[:state]).to eq(:running)
      expect(run.properties[:name]).to start_with("◐")

      bridge.apply("test ok bundle exec rspec")      # process 2: same digest key
      g = graph
      runs = g.nodes.select { |n| n.type == :TestRun }
      expect(runs.size).to eq(1) # re-emitted, not duplicated — latest fold wins
      expect(runs.first.id).to eq(run.id)
      expect(runs.first.properties[:state]).to eq(:passed)
      expect(runs.first.properties[:name]).to start_with("✓")
    end

    it "marks a failure with its own state and glyph" do
      bridge.apply("test fail bundle exec rspec")
      run = graph.nodes.find { |n| n.type == :TestRun }
      expect(run.properties[:state]).to eq(:failed)
      expect(run.properties[:name]).to start_with("✗")
      expect(run.properties[:output].join).to include("FAILED")
    end
  end

  it "ignores an unknown verb without crashing the stream" do
    b = bridge
    b.apply("edit lib/foo.rb")
    expect { b.apply("frobnicate whatever") }.to output(/unknown command/).to_stderr
    expect(graph.nodes.map(&:type)).to include(:ProposedChange) # earlier events intact
  end
end
