# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

# The beads provider: a project's issue database walked as columns. Exercised
# against a fake client (the Client duck-type: index/deps_for/issues_by_ids/
# body), so no dolt server or mysql gem is needed — the SQL edge is the one
# thing these specs don't cover (the live probe does).
RSpec.describe HColumns::Providers::Beads do
  BEADS = HColumns::Providers::Beads

  def now = FIXED_NOW

  # A semantic stand-in for Beads::Client — same four methods, plain data.
  class FakeBeadsClient
    def initialize(issues:, deps: [])
      @issues = issues
      @deps = deps
    end

    def index(limit:)
      open_first = @issues.sort_by { |i| [i[:status] == "closed" ? 1 : 0, i[:priority], i[:id]] }
      open_first.first(limit)
    end

    def deps_for(id)
      @deps.select { |d| d[:issue_id] == id || d[:depends_on_id] == id }
    end

    def issues_by_ids(ids)
      @issues.select { |i| ids.include?(i[:id]) }
    end

    def body(id)
      @issues.find { |i| i[:id] == id }
    end
  end

  ISSUES = [
    { id: "hc-epic", title: "The epic", status: "open", priority: 1, issue_type: "epic",
      description: "Parent of everything. See lib/real.rb for the seam.", metadata: nil },
    { id: "hc-child", title: "A subtask", status: "in_progress", priority: 1, issue_type: "task",
      description: "Child work.", metadata: { "files" => ["lib/real.rb", "lib/ghost.rb"] }.to_json },
    { id: "hc-blocked", title: "Waits on the epic", status: "open", priority: 2, issue_type: "task",
      description: "", metadata: nil },
    { id: "hc-done", title: "Old finished thing", status: "closed", priority: 0, issue_type: "chore",
      description: "", metadata: nil }
  ].freeze

  DEPS = [
    { issue_id: "hc-child", depends_on_id: "hc-epic", type: "parent-child" },
    { issue_id: "hc-blocked", depends_on_id: "hc-epic", type: "blocks" },
    { issue_id: "hc-child", depends_on_id: "hc-blocked", type: "discovered-from" }
  ].freeze

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@root, ".beads"))
      File.write(File.join(@root, ".beads", "metadata.json"), { "dolt_database" => "hc" }.to_json)
      FileUtils.mkdir_p(File.join(@root, "lib"))
      File.write(File.join(@root, "lib", "real.rb"), "# exists\n")
      example.run
    ensure
      BEADS.reset_clients!
    end
  end

  let(:client) { FakeBeadsClient.new(issues: ISSUES.map(&:dup), deps: DEPS) }
  let(:provider) { BEADS.new(@root, client: client) }
  let(:workspace) { HColumns::Workspace.new(providers: [provider]) }

  def root_node
    workspace.add_node(HColumns::Providers::Filesystem.node_for(@root))
  end

  def column(id)
    workspace.column_for(id, now: now)
  end

  def descend(column, relation)
    group = column.groups.find { |g| g.relation == relation }
    expect(group).not_to be_nil, "expected a #{relation} group in #{column.groups.map(&:relation)}"
    group
  end

  it "finds the beads root by walking up, and only there" do
    nested = File.join(@root, "lib")
    expect(BEADS.root_for(nested)).to eq(@root)
    expect(BEADS.root_for(Dir.tmpdir)).to be_nil
  end

  it "hangs a beads index off the project root" do
    group = descend(column(root_node.id), :HAS_BEADS)
    index = group.entries.first.target
    expect(index.type).to eq(:Beads)
    expect(index.name).to eq("beads (hc)")
    expect(group.entries.first.confidence).to eq(1.0) # a declared fact
  end

  it "lists the beads under the index, closed issues ranked last" do
    index_id = descend(column(root_node.id), :HAS_BEADS).entries.first.target.id
    entries = descend(column(index_id), :HAS_BEAD).entries
    expect(entries.map { |e| e.target.type }.uniq).to eq([:Bead])
    ids = entries.map { |e| e.target.properties[:bead_id] }
    expect(ids).to contain_exactly("hc-epic", "hc-child", "hc-blocked", "hc-done")
  end

  describe "a bead's dependency edges" do
    def bead_column(bead_id)
      node = workspace.add_node(BEADS.bead_node(@root, ISSUES.find { |i| i[:id] == bead_id }))
      column(node.id)
    end

    it "maps parent-child both ways: HAS_CHILD from the parent, CHILD_OF from the child" do
      children = descend(bead_column("hc-epic"), :HAS_CHILD).entries
      expect(children.map { |e| e.target.properties[:bead_id] }).to include("hc-child")

      parents = descend(bead_column("hc-child"), :CHILD_OF).entries
      expect(parents.map { |e| e.target.properties[:bead_id] }).to eq(["hc-epic"])
    end

    it "maps blocks both ways: BLOCKS from the blocker, BLOCKED_BY from the blocked" do
      expect(descend(bead_column("hc-epic"), :BLOCKS).entries.map { |e| e.target.properties[:bead_id] })
        .to include("hc-blocked")
      expect(descend(bead_column("hc-blocked"), :BLOCKED_BY).entries.map { |e| e.target.properties[:bead_id] })
        .to eq(["hc-epic"])
    end

    it "walks unknown dependency kinds under their upcased name" do
      expect(descend(bead_column("hc-child"), :DISCOVERED_FROM).entries.map { |e| e.target.properties[:bead_id] })
        .to eq(["hc-blocked"])
    end

    it "keeps declared structure at confidence 1.0" do
      expect(descend(bead_column("hc-epic"), :HAS_CHILD).entries.map(&:confidence)).to all(eq(1.0))
    end
  end

  describe "file links (TOUCHES)" do
    def touches(bead_id)
      node = workspace.add_node(BEADS.bead_node(@root, ISSUES.find { |i| i[:id] == bead_id }))
      column(node.id).groups.find { |g| g.relation == :TOUCHES }
    end

    it "links metadata-listed files that exist, as the agent's word (< 1.0)" do
      entries = touches("hc-child").entries
      expect(entries.size).to eq(1) # lib/ghost.rb doesn't exist -> no edge
      entry = entries.first
      expect(entry.target.identity[:scheme]).to eq("fs.path") # unifies with the code graph
      expect(entry.confidence).to be_between(0.1, 0.99)
    end

    it "links paths mentioned in prose, as a weaker guess than metadata" do
      prose = touches("hc-epic").entries.first
      listed = touches("hc-child").entries.first
      expect(prose.target.name.to_s).to end_with("real.rb")
      expect(prose.confidence).to be < listed.confidence
    end
  end

  describe "endpoint resolution" do
    it "reads the database name from metadata.json and defaults to the repo's port" do
      ep = BEADS.endpoint(@root)
      expect(ep[:database]).to eq("hc")
      expect(ep[:port]).to eq(3307)
    end

    it "prefers the repo's own port file when present" do
      File.write(File.join(@root, ".beads", "dolt-server.port"), "3399\n")
      expect(BEADS.endpoint(@root)[:port]).to eq(3399)
    end

    it "returns nil when there is no database to name (never guesses)" do
      File.write(File.join(@root, ".beads", "metadata.json"), "{}")
      expect(BEADS.endpoint(@root)).to be_nil
    end
  end

  describe "modes" do
    let(:resolver) { HColumns::ModeResolver.new }

    it "gives a Bead the bead facet as a tab, default column as auto" do
      node = workspace.add_node(BEADS.bead_node(@root, ISSUES.first))
      names = resolver.modes_for(node).map(&:name)
      expect(names.first).to eq(:default)
      expect(names).to include(:bead, :details) if BEADS.available?
    end

    it "renders the bead body from the shared client" do
      skip "ruby-mysql not installed" unless BEADS.available?

      node = workspace.add_node(BEADS.bead_node(@root, ISSUES.first))
      panel = HColumns::Mode[:bead].panel(node, workspace, now: now)
      lines = panel.sections.flat_map(&:lines)
      expect(lines.first).to eq("hc-epic — The epic")
      expect(lines).to include("P1 · epic · open")
      expect(panel.sections.map(&:heading)).to include("DESCRIPTION")
    end
  end

  it "survives a dead client without crashing the walk" do
    broken = Class.new do
      def index(limit:) = raise("connection lost")
    end.new
    BEADS.attach_client(@root, broken)
    prov = BEADS.new(@root)
    ws = HColumns::Workspace.new(providers: [prov])
    index = ws.add_node(BEADS.index_node(@root, "hc"))
    expect { expect(ws.column_for(index.id, now: now).groups).to be_empty }
      .to output(/beads: connection lost/).to_stderr
  end
end
