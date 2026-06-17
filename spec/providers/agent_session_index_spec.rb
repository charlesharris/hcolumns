# frozen_string_literal: true

# The sessions index: walk a list of sessions and descend into any one's route.
RSpec.describe "AgentSession sessions index" do
  def now = FIXED_NOW

  AS = HColumns::Providers::AgentSession

  let(:graph) { AS.sessions_graph(now: now) }
  let(:workspace) { HColumns::Workspace.new(graph: graph) }

  def column(id)
    workspace.column_for(id, now: now)
  end

  it "lists every session under the index via HAS_SESSION" do
    group = column(AS.index_id).groups.find { |g| g.relation == :HAS_SESSION }
    expect(group.entries.size).to eq(AS::SESSIONS.size)
    expect(group.entries.map { |e| e.target.type }.uniq).to eq([:Session])
    expect(group.entries.map(&:confidence)).to all(eq(1.0)) # the list really contains them
  end

  it "lets you descend into any listed session's full route" do
    %w[s1 s2 s3].each do |key|
      id = HColumns::Identity.id_for(scheme: "agent.session", key: key)
      expect(column(id).groups.map(&:relation)).to include(:DRIVEN_BY, :PROPOSES)
    end
  end

  it "leaves the live session a shell when live_key is given, but still lists it" do
    g = AS.sessions_graph(now: now, live_key: "s1")
    w = HColumns::Workspace.new(graph: g)

    session = w.column_for(AS.session_id, now: now)
    expect(session.groups.map(&:relation)).not_to include(:PROPOSES) # route arrives via the feed

    listed = w.column_for(AS.index_id, now: now).groups.first.entries.map { |e| e.target.id }
    expect(listed).to include(AS.session_id)
  end
end
