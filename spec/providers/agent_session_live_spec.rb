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

  # Section headings of the active panel (relation families for a lens column).
  def headings(cascade)
    cascade.active_panel.sections.map(&:heading)
  end

  it "starts with only what is known at t0 and reports itself live" do
    cascade = fresh_cascade
    expect(cascade.live?).to be true
    expect(headings(cascade)).to contain_exactly("DRIVEN_BY")
  end

  it "grows the session column when the agent proposes a change (~1s)" do
    cascade = fresh_cascade
    expect(cascade.tick(1.2)).to be true
    expect(headings(cascade)).to include("PROPOSES")
  end

  it "does not repaint when a tick releases nothing (no idle flicker)" do
    cascade = fresh_cascade
    cascade.tick(1.2)
    expect(cascade.tick(1.3)).to be false # nothing new is due between 1.2 and 1.3
  end

  it "grows a frame the walker has already descended into (the diff facet)" do
    cascade = fresh_cascade
    cascade.tick(1.2) # PROPOSES now exists

    change = cascade.active_entries.index { |e| e.label.include?("diff:") }
    cascade.move(change)
    cascade.into
    expect(cascade.active_mode.name).to eq(:diff) # a ProposedChange opens on the diff facet

    cascade.tick(2.2) # a couple of files touched so far
    files_early = cascade.active_entries.length

    cascade.tick(5.0) # the rest of the diff + the test run land
    expect(cascade.active_entries.length).to be > files_early
    status = cascade.active_panel.sections.flat_map(&:lines).join(" ")
    expect(status).to include("✓") # the verification status arrived
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
