# frozen_string_literal: true

require "tmpdir"

# The one-server seam: BridgeMount folds a tailed agent-bridge log into a HOST
# graph (the project directory's) and hangs the log's Session under the host's
# root — root -HAS_SESSION-> session, emitted at mount time so the log itself
# stays path-independent.
RSpec.describe HColumns::BridgeMount do
  def now = FIXED_NOW

  around do |example|
    Dir.mktmpdir("hcol-mount") do |dir|
      @log = File.join(dir, "live.jsonl")
      example.run
    end
  end

  def write_bridge(*commands, session: "s1")
    bridge = HColumns::AgentBridge.new(path: @log, session: session, clock: -> { now })
    commands.each { |c| bridge.apply(c) }
  end

  def host_graph
    graph = HColumns::Graph.new
    root = graph.add_node(HColumns::Node.new(
                            type: :Directory, identity: { scheme: "fs.path", key: "local:/host" },
                            properties: { name: "host" }
                          ))
    [graph, root]
  end

  def mount_over(graph, root)
    described_class.new(HColumns::TailReader.new(@log), root_id: root.id, now: now)
  end

  def seam_edges(graph, root)
    graph.edges_from(root.id).select { |e| e.type == :HAS_SESSION }
  end

  it "hangs the log's session under the host root as events land" do
    write_bridge("edit lib/foo.rb")
    graph, root = host_graph
    mount = mount_over(graph, root)

    expect(mount.release(into: graph)).to be(true)
    edge = seam_edges(graph, root).first
    expect(edge).not_to be_nil
    session = graph.node(edge.target_id)
    expect(session.type).to eq(:Session)
    expect(edge.confidence(now: now)).to eq(1.0) # the seam is structural, not inferred
  end

  it "mounts a return path too (session -IN_PROJECT-> root): the walk goes both ways" do
    write_bridge("edit lib/foo.rb")
    graph, root = host_graph
    mount = mount_over(graph, root)
    mount.release(into: graph)

    back = graph.edges_from(mount.session_id).find { |e| e.type == :IN_PROJECT }
    expect(back).not_to be_nil
    expect(back.target_id).to eq(root.id) # a session-rooted view reaches the project strata
  end

  it "emits the seam edge once, however many times the log speaks" do
    write_bridge("edit lib/foo.rb")
    graph, root = host_graph
    mount = mount_over(graph, root)
    mount.release(into: graph)

    write_bridge("test ok bundle exec rspec", "phase reviewing")
    mount.release(into: graph)

    expect(seam_edges(graph, root).length).to eq(1)
  end

  it "mounts the same log under any root (the edge lives here, not in the log)" do
    write_bridge("edit lib/foo.rb")
    [host_graph, host_graph].each do |graph, root|
      mount_over(graph, root).release(into: graph)
      expect(seam_edges(graph, root).length).to eq(1)
    end
  end

  it "exposes the mounted session's id for the host's SessionContext wiring" do
    write_bridge("edit lib/foo.rb", "phase testing")
    graph, root = host_graph
    mount = mount_over(graph, root)
    expect(mount.session_id).to be_nil # nothing mounted yet

    mount.release(into: graph)
    session = graph.node(mount.session_id)
    expect(session.properties[:phase]).to eq(:testing)
  end

  it "the session tab is a stratum switcher: the session lens floats the seam to the top" do
    write_bridge("edit lib/foo.rb")
    graph, root = host_graph
    # a filesystem stratum beside the session's, so there's an order to flip
    file = graph.add_node(HColumns::Node.new(
                            type: :File, identity: { scheme: "fs.path", key: "local:/host/a.rb" },
                            properties: { name: "a.rb" }
                          ))
    graph.observe(HColumns::Observation.new(
                    provider: :fs, subject_id: root.id, target_id: file.id, edge_type: :CONTAINS,
                    weight: 1.0, evidence_kind: :structure, observed_at: now, evidence_summary: "dir entry"
                  ))
    mount_over(graph, root).release(into: graph)

    order_under = lambda do |lens|
      HColumns::ColumnBuilder.new(graph, lens: lens).build(root.id, now: now).groups.map(&:relation)
    end
    expect(order_under.call(HColumns::Lens.preset(:session)).first).to eq(:HAS_SESSION)
    expect(order_under.call(HColumns::Lens.preset(:filesystem)).first).to eq(:CONTAINS)
  end

  it "stays a Feed: log and done? delegate to the tail underneath" do
    write_bridge("edit lib/foo.rb")
    graph, root = host_graph
    mount = mount_over(graph, root)
    mount.release(into: graph)

    expect(mount.done?).to be(false) # an accreting bridge log is never complete
    expect(mount.log.version).to be > 0
  end
end
