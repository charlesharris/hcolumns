# frozen_string_literal: true

# The guiding-star behaviour (option B): the column grows as the agent "works".
# Driven through Cascade#tick with explicit elapsed times, so the live walk is
# tested deterministically without a TTY or any wall-clock.
RSpec.describe "AgentSession live feed" do
  def now = FIXED_NOW

  AS = HColumns::Providers::AgentSession

  def fresh_cascade
    feed = AS.feed(now: now)
    graph = HColumns::Graph.new
    feed.release(0.0, into: graph) # seed: the task + its driver
    workspace = HColumns::Workspace.new(graph: graph)
    HColumns::Cascade.new(workspace, AS.session_id, now: now, feed: feed)
  end

  def relations(column)
    column.groups.map(&:relation)
  end

  def count(column, relation)
    column.groups.find { |g| g.relation == relation }&.entries&.size || 0
  end

  it "starts with only what is known at t0 and reports itself live" do
    cascade = fresh_cascade
    expect(cascade.live?).to be true
    expect(relations(cascade.active_column)).to contain_exactly(:DRIVEN_BY)
  end

  it "grows the session column when the agent proposes a change (~1s)" do
    cascade = fresh_cascade
    expect(cascade.tick(1.2)).to be true
    expect(relations(cascade.active_column)).to include(:PROPOSES)
  end

  it "does not repaint when a tick releases nothing (no idle flicker)" do
    cascade = fresh_cascade
    cascade.tick(1.2)
    expect(cascade.tick(1.3)).to be false # nothing new is due between 1.2 and 1.3
  end

  it "grows a frame the walker has already descended into" do
    cascade = fresh_cascade
    cascade.tick(1.2) # PROPOSES now exists

    proposes = cascade.active_entries.index { |e| e.relation == :PROPOSES }
    cascade.move(proposes)
    cascade.into
    expect(cascade.active_column.root.type).to eq(:ProposedChange)

    cascade.tick(2.2) # a couple of files touched so far
    touched_early = count(cascade.active_column, :TOUCHES)

    cascade.tick(5.0) # the rest of the diff + the test run land
    expect(count(cascade.active_column, :TOUCHES)).to be > touched_early
    expect(relations(cascade.active_column)).to include(:VERIFIED_BY)
  end

  it "folds to the same projection as the frozen build once fully elapsed" do
    feed = AS.feed(now: now)
    graph = HColumns::Graph.new
    feed.release(99.0, into: graph) # the whole timeline

    frozen = AS.build(now: now)
    edge = ->(g) { g.edges.map { |e| [e.subject_id, e.target_id, e.type] }.sort }
    expect(edge.(graph)).to eq(edge.(frozen))
    expect(graph.nodes.map(&:id).sort).to eq(frozen.nodes.map(&:id).sort)
  end
end
