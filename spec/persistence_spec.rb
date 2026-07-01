# frozen_string_literal: true

RSpec.describe HColumns::Persistence do
  def now = FIXED_NOW

  def node(key, props = {})
    HColumns::Node.new(type: :SourceFile, identity: { scheme: "fs.path", key: key },
                       properties: { name: key }.merge(props))
  end

  def observation(subject, target, type, kind: :structure)
    HColumns::Observation.new(provider: :agent, subject_id: subject.id, target_id: target.id,
                              edge_type: type, evidence_kind: kind, observed_at: now,
                              evidence_summary: "because")
  end

  describe HColumns::Persistence::Codec do
    it "round-trips symbols, times, and nested structures faithfully" do
      value = { name: "claude", phase: :reviewing, at: now,
                tags: [:a, "b", 3], nested: { deep: :sym } }
      expect(described_class.load(described_class.dump(value))).to eq(value)
    end

    it "preserves a symbol *value* as a Symbol (not a string)" do
      loaded = described_class.load(described_class.dump({ phase: :editing }))
      expect(loaded[:phase]).to be_a(Symbol).and eq(:editing)
    end

    it "preserves string keys in a mixed/string-keyed hash (a diff's hunks)" do
      hunks = { "lib/a.rb" => ["+x"], "spec/a_spec.rb" => ["+y"] }
      loaded = described_class.load(described_class.dump(hunks))
      expect(loaded.keys).to all(be_a(String))
      expect(loaded).to eq(hunks)
    end

    it "reconstructs a Time to the same instant" do
      expect(described_class.load(described_class.dump(now))).to eq(now)
    end
  end

  it "round-trips an event log so the projection matches (ids, edges, confidence)" do
    log = HColumns::EventLog.new
    graph = HColumns::Graph.new(log: log)
    a = node("a")
    b = node("b")
    graph.add_node(a)
    graph.add_node(b)
    graph.observe(observation(a, b, :CONTAINS))
    graph.observe(observation(a, b, :CO_CHANGED_WITH, kind: :history))

    reloaded = described_class.load_string(described_class.dump_string(log))
    expect(reloaded.version).to eq(log.version)

    original = log.project
    replayed = reloaded.project
    expect(replayed.nodes.map(&:id)).to match_array(original.nodes.map(&:id))
    expect(replayed.edges.map { |e| [e.subject_id, e.target_id, e.type] })
      .to match_array(original.edges.map { |e| [e.subject_id, e.target_id, e.type] })
    original.edges.zip(replayed.edges).each do |o, r|
      expect(r.confidence(now: now)).to be_within(1e-9).of(o.confidence(now: now))
    end
  end

  it "keeps a node's properties (name, path, symbol phase) through a round-trip" do
    log = HColumns::EventLog.new
    log.append(kind: :node, payload: node("s", phase: :debugging, path: "s"))
    reloaded = described_class.load_string(described_class.dump_string(log))
    props = reloaded.project.node(node("s").id).properties
    expect(props[:phase]).to eq(:debugging)
    expect(props[:name]).to eq("s")
  end

  it "reports the log's root as the first node to come into being" do
    log = HColumns::EventLog.new
    root = node("root")
    log.append(kind: :node, payload: root)
    log.append(kind: :node, payload: node("child"))
    expect(described_class.root_id(log)).to eq(root.id)
  end

  describe "a real agent session snapshot" do
    let(:log) do
      feed = HColumns::Providers::AgentSession.feed(now: now)
      feed.release(Float::INFINITY, into: HColumns::Graph.new)
      feed.log
    end

    it "reloads to an equivalent, walkable session graph" do
      reloaded = described_class.load_string(described_class.dump_string(log))
      graph = reloaded.project

      session = graph.node(HColumns::Providers::AgentSession.session_id)
      expect(session).not_to be_nil
      # the last re-emitted phase wins in the frozen fold, and it stays a Symbol —
      # so PHASE_PREFERENCE biasing still fires after a reload.
      expect(session.properties[:phase]).to eq(:reviewing)
      expect(described_class.root_id(reloaded)).to eq(session.id)
    end

    it "keeps the diff hunks keyed by file-path String" do
      graph = described_class.load_string(described_class.dump_string(log)).project
      change = graph.nodes.find { |n| n.type == :ProposedChange }
      expect(change.properties[:hunks].keys).to all(be_a(String))
      expect(change.properties[:hunks]).to eq(HColumns::Providers::AgentSession.spec_for("s1")[:hunks])
    end
  end
end
