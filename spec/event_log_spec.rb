# frozen_string_literal: true

RSpec.describe HColumns::EventLog do
  def now = FIXED_NOW

  def node(key)
    HColumns::Node.new(type: :SourceFile, identity: { scheme: "fs.path", key: key }, properties: { name: key })
  end

  def observation(subject, target, type)
    HColumns::Observation.new(provider: :test, subject_id: subject.id, target_id: target.id,
                              edge_type: type, evidence_kind: :structure, observed_at: now)
  end

  it "stamps events with monotonic sequence numbers and tracks a version" do
    log = described_class.new
    a = log.append(kind: :node, payload: node("a"))
    b = log.append(kind: :node, payload: node("b"))
    expect([a.seq, b.seq]).to eq([0, 1])
    expect(log.version).to eq(2)
  end

  it "exposes the tail since a given seq (what a live consumer hasn't folded)" do
    log = described_class.new
    log.append(kind: :node, payload: node("a"))
    mark = log.version
    log.append(kind: :node, payload: node("b"))
    expect(log.since(mark).map { |e| e.payload.name }).to eq(["b"])
    expect(log.since(log.version)).to eq([]) # caught up
  end

  it "replays into a projection equal to an incrementally log-backed graph" do
    # Build a graph that records into a log as it is mutated (the 2b seam:
    # providers call observe/add_node unchanged; the log fills transparently).
    log = HColumns::EventLog.new
    live = HColumns::Graph.new(log: log)
    a = node("a")
    b = node("b")
    live.add_node(a)
    live.add_node(b)
    live.observe(observation(a, b, :CONTAINS))

    expect(log.version).to eq(3)

    # Replaying that log from scratch reproduces the same projection.
    replayed = log.project
    expect(replayed.nodes.map(&:id)).to match_array(live.nodes.map(&:id))
    expect(replayed.edges.map { |e| [e.subject_id, e.target_id, e.type] })
      .to eq(live.edges.map { |e| [e.subject_id, e.target_id, e.type] })
    expect(replayed.edges.first.confidence(now: now)).to eq(live.edges.first.confidence(now: now))
  end

  it "folding the tail does not re-record (a projection is log-less)" do
    log = described_class.new
    log.append(kind: :node, payload: node("a"))
    projection = log.project # folds via apply_*, which records nothing
    expect(log.version).to eq(1)
    expect(projection.node(node("a").id)).not_to be_nil
  end
end
