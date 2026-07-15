# frozen_string_literal: true

require "tmpdir"

RSpec.describe HColumns::TailReader do
  def now = FIXED_NOW

  def node(key)
    HColumns::Node.new(type: :SourceFile, identity: { scheme: "fs.path", key: key },
                       properties: { name: key })
  end

  def observation(subject, target, type)
    HColumns::Observation.new(provider: :agent, subject_id: subject.id, target_id: target.id,
                              edge_type: type, evidence_kind: :structure, observed_at: now)
  end

  around do |example|
    Dir.mktmpdir { |dir| @path = File.join(dir, "live.jsonl"); example.run }
  end

  def append(*lines)
    File.open(@path, "a") { |f| lines.each { |l| f.puts(l) } }
  end

  def line(kind, payload)
    HColumns::Persistence.line_for(kind: kind, payload: payload)
  end

  it "folds newly-appended events into the projection and signals growth" do
    reader = described_class.new(@path)
    graph = HColumns::Graph.new
    a = node("a")
    b = node("b")

    expect(reader.release(into: graph)).to be(false) # nothing yet (no file)

    append(line(:node, a), line(:node, b))
    expect(reader.release(into: graph)).to be(true)
    expect(graph.nodes.map(&:id)).to match_array([a.id, b.id])

    append(line(:observe, observation(a, b, :CONTAINS)))
    expect(reader.release(into: graph)).to be(true)
    expect(graph.edges_from(a.id).map(&:type)).to eq([:CONTAINS])

    expect(reader.release(into: graph)).to be(false) # caught up
  end

  it "waits for a newline before folding a half-written line" do
    reader = described_class.new(@path)
    graph = HColumns::Graph.new
    full = line(:node, node("a"))
    half, rest = full[0...10], full[10..]

    File.open(@path, "a") { |f| f.write(half) } # no newline yet
    expect(reader.release(into: graph)).to be(false)
    expect(graph.nodes).to be_empty

    File.open(@path, "a") { |f| f.puts(rest) } # completes the line
    expect(reader.release(into: graph)).to be(true)
    expect(graph.node(node("a").id)).not_to be_nil
  end

  it "flips done? on the eof marker" do
    reader = described_class.new(@path)
    graph = HColumns::Graph.new
    append(line(:node, node("a")))
    reader.release(into: graph)
    expect(reader.done?).to be(false)

    append(HColumns::Persistence.eof_line)
    reader.release(into: graph)
    expect(reader.done?).to be(true)
  end

  it "un-flips done? when an accreting log speaks again after a stale eof" do
    reader = described_class.new(@path)
    graph = HColumns::Graph.new
    append(line(:node, node("a")), HColumns::Persistence.eof_line) # a past session's close
    append(line(:node, node("b")))                                 # the next session appends

    expect(reader.release(into: graph)).to be(true)
    expect(reader.done?).to be(false) # the stale marker mid-log must not deafen the tail
    expect(graph.node(node("b").id)).not_to be_nil
  end

  it "exposes its own log so the projection can be re-persisted or versioned" do
    reader = described_class.new(@path)
    graph = HColumns::Graph.new
    append(line(:node, node("a")), line(:node, node("b")))
    reader.release(into: graph)
    expect(reader.log.version).to eq(2)
    expect(HColumns::Persistence.root_id(reader.log)).to eq(node("a").id)
  end
end
