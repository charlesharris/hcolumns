# frozen_string_literal: true

# Turns (juggler takeaway #1, docs/notes/juggler-survey.md): a :turn marker event
# partitions the log; membership and ordinals are DERIVED at fold time from log
# order — producers stay stateless, replay stays deterministic, and dropping the
# markers yields the same edges (turns are provenance grouping, not evidence).
RSpec.describe "turn grouping" do
  def now = FIXED_NOW

  def obs(subject, target, at: now)
    HColumns::Observation.new(provider: :agent, subject_id: subject.id, target_id: target.id,
                              edge_type: :TOUCHES, weight: 1.0, evidence_kind: :structure,
                              observed_at: at, evidence_summary: "touched")
  end

  let(:log) { HColumns::EventLog.new }
  let(:graph) { HColumns::Graph.new(log: log) }
  let(:session) { graph.add_node(HColumns::Node.new(type: :Session, identity: { scheme: "agent.session", key: "s1" }, properties: { name: "s1" })) }
  let(:change) { graph.add_node(HColumns::Node.new(type: :ProposedChange, identity: { scheme: "agent.change", key: "c1" }, properties: { name: "c1" })) }
  let(:file_a) { graph.add_node(HColumns::Node.new(type: :SourceFile, identity: { scheme: "fs.path", key: "local:/r/a.rb" }, properties: { name: "a.rb" })) }
  let(:file_b) { graph.add_node(HColumns::Node.new(type: :SourceFile, identity: { scheme: "fs.path", key: "local:/r/b.rb" }, properties: { name: "b.rb" })) }

  it "assigns ordinals from fold order and stamps observations with their turn" do
    graph.record_turn(label: "first ask", at: now)
    graph.observe(obs(change, file_a))
    graph.record_turn(label: "second ask", at: now)
    graph.observe(obs(change, file_b))

    expect(graph.turns.map { |t| [t[:index], t[:label]] }).to eq([[1, "first ask"], [2, "second ask"]])
    touches = graph.edges_from(change.id).select { |e| e.type == :TOUCHES }
    by_target = touches.to_h { |e| [e.target_id, e.observations.first.turn[:index]] }
    expect(by_target[file_a.id]).to eq(1)
    expect(by_target[file_b.id]).to eq(2)
  end

  it "leaves observations before the first marker unattributed" do
    graph.observe(obs(change, file_a)) # no marker yet — e.g. the bridge header
    graph.record_turn(label: "ask", at: now)
    graph.observe(obs(change, file_b))

    turns_by_target = graph.edges_from(change.id).to_h { |e| [e.target_id, e.observations.first.turn] }
    expect(turns_by_target[file_a.id]).to be_nil
    expect(turns_by_target[file_b.id]).not_to be_nil
  end

  it "derives the same turns replaying whole or folding one event at a time (the tail path)" do
    graph.record_turn(label: "one", at: now)
    graph.observe(obs(change, file_a))
    graph.record_turn(label: "two", at: now)
    graph.observe(obs(change, file_b))

    replayed = log.project
    incremental = HColumns::Graph.new
    log.events.each { |e| log.fold([e], into: incremental) }

    [replayed, incremental].each do |g|
      expect(g.turns.map { |t| t[:index] }).to eq([1, 2])
      stamped = g.edges_from(change.id).map { |e| e.observations.first.turn[:index] }.sort
      expect(stamped).to eq([1, 2])
    end
  end

  it "collects each turn's touched nodes for the facet" do
    graph.record_turn(label: "ask", at: now)
    graph.observe(obs(change, file_a))
    graph.observe(obs(change, file_a)) # touched twice, listed once
    expect(graph.turns.first[:node_ids].uniq).to eq([file_a.id])
  end

  it "survives the JSONL round-trip: markers persist, membership re-derives on load" do
    graph.record_turn(label: "ask", at: now)
    graph.observe(obs(change, file_a))
    reloaded = HColumns::Persistence.load_string(HColumns::Persistence.dump_string(log)).project

    expect(reloaded.turns.map { |t| t[:label] }).to eq(["ask"])
    stamped = reloaded.edges_from(change.id).first.observations.first.turn
    expect(stamped[:index]).to eq(1)
  end

  describe HColumns::TurnsMode do
    let(:mode) { HColumns::Mode[:turns] }
    let(:workspace) { HColumns::Workspace.new(graph: graph) }

    it "offers the tab on a Session and lists each turn's nodes, walkable" do
      graph.record_turn(label: "fix the parser", at: now)
      graph.observe(obs(change, file_a))

      expect(mode.applies?(session)).to be true
      expect(mode.applies?(file_a)).to be false
      panel = mode.panel(session, workspace, now: now)
      section = panel.sections.first
      expect(section.heading).to eq("TURN 1 — fix the parser (1 node)")
      expect(section.items.first.target_id).to eq(file_a.id) # descendable
    end

    it "is ranked by the resolver as a Session tab" do
      expect(HColumns::ModeResolver.new.modes_for(session).map(&:name)).to include(:turns)
    end

    it "renders an honest empty state when the log carried no markers" do
      panel = mode.panel(session, workspace, now: now)
      expect(panel.sections.first.lines.join).to include("no turns recorded")
    end
  end

  describe "the inspector" do
    it "tags each observation with the turn that produced it" do
      graph.record_turn(label: "ask", at: now)
      graph.observe(obs(change, file_a))
      out = HColumns::Renderers::Detail.new.node(file_a, graph, lens: HColumns::Lens.new(name: :default), now: now)
      expect(out).to include("turn 1 (ask)")
    end
  end
end
