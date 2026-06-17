# frozen_string_literal: true

RSpec.describe HColumns::Providers::AgentSession do
  def now = FIXED_NOW

  let(:graph) { described_class.build(now: now) }
  let(:workspace) { HColumns::Workspace.new(graph: graph) }

  def column_for(scheme, key)
    workspace.column_for(HColumns::Identity.id_for(scheme: scheme, key: key), now: now)
  end

  def relations(column)
    column.groups.map(&:relation)
  end

  def entry(column, relation)
    column.groups.find { |g| g.relation == relation }&.entries
  end

  it "roots at a Session whose column proposes a change and names its driver" do
    col = column_for("agent.session", "s1")
    expect(col.root.type).to eq(:Session)
    expect(relations(col)).to include(:PROPOSES, :DRIVEN_BY)

    proposes = entry(col, :PROPOSES)
    expect(proposes.size).to eq(1)
    expect(proposes.first.target.type).to eq(:ProposedChange)
  end

  it "walks the route Change -> touched files / test, with the test reachable from the change" do
    col = column_for("agent.change", "s1:c1")
    expect(col.root.type).to eq(:ProposedChange)
    expect(relations(col)).to include(:TOUCHES, :VERIFIED_BY)

    touched = entry(col, :TOUCHES).map { |e| e.target.name }
    expect(touched).to include("lib/hcolumns/providers/agent_session.rb")

    verified = entry(col, :VERIFIED_BY)
    expect(verified.first.target.type).to eq(:TestRun)
  end

  it "reaches the log line emitted by the test run (the tail of the route)" do
    col = column_for("agent.test", "s1:t1")
    emitted = entry(col, :EMITTED)
    expect(emitted.first.target.type).to eq(:LogLine)
  end

  it "separates verifiable ground truth from the agent's assertions in confidence" do
    col = column_for("agent.change", "s1:c1")

    # the diff verifiably touches these files -> deterministic, pinned to 1.0
    expect(entry(col, :TOUCHES).map(&:confidence)).to all(eq(1.0))

    # "this is the focus" is the agent's emphasis, not a fact -> probabilistic, < 1.0
    focuses = entry(col, :FOCUSES_ON).first
    expect(focuses.confidence).to be < 1.0
    expect(focuses.confidence).to be > 0.5
  end

  it "carries the agent's final phase on the session node (event-sourced)" do
    expect(graph.node(described_class.session_id).properties[:phase]).to eq(:reviewing)
  end

  it "gives touched files real fs.path identities so they unify with the code graph" do
    change = column_for("agent.change", "s1:c1")
    touched = entry(change, :TOUCHES).find { |e| e.target.name == "lib/hcolumns/evidence.rb" }
    fs_id = HColumns::Identity.id_for(scheme: "fs.path", key: "local:/repo/lib/hcolumns/evidence.rb")
    expect(touched.target.id).to eq(fs_id)
  end
end
