# frozen_string_literal: true

require "tmpdir"

# The missing read affordance (hc-lmh): find nodes without an address to start
# from. Graph-native — one capped breadth-first materialization reaches every
# stratum, so a future provider's nodes are searchable for free.
RSpec.describe HColumns::Searcher do
  def now = FIXED_NOW

  describe "over a pre-folded graph" do
    let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
    let(:workspace) { HColumns::Workspace.new(graph: graph) }
    let(:root) { graph.nodes.find { |n| n.name == "repo/" }.id }

    it "matches name substrings case-insensitively, sorted by type then name" do
      matches = described_class.new(workspace, now: now).find("ORDERS", from: root)
      expect(matches).not_to be_empty
      expect(matches.map { |n| n.name.to_s }).to all(match(/orders/i))
      expect(matches).to eq(matches.sort_by { |n| [n.type.to_s, n.name.to_s.downcase] })
    end

    it "narrows by node type" do
      all = described_class.new(workspace, now: now).find("orders", from: root)
      files = described_class.new(workspace, now: now).find("orders", from: root, type: "SourceFile")
      expect(files.map(&:type).uniq).to eq([:SourceFile])
      expect(files.size).to be < all.size
    end

    it "reports a tripped cap instead of reading as searched-everything" do
      capped = described_class.new(workspace, now: now, node_cap: 2)
      capped.find("orders", from: root)
      expect(capped.capped?).to be(true)

      roomy = described_class.new(workspace, now: now)
      roomy.find("orders", from: root)
      expect(roomy.capped?).to be(false)
    end
  end

  describe "over lazy pull providers (the reach IS the materialization)" do
    it "finds a file the workspace had never expanded to" do
      Dir.mktmpdir("hcol-search") do |dir|
        FileUtils.mkdir_p(File.join(dir, "deep", "deeper"))
        File.write(File.join(dir, "deep", "deeper", "needle.rb"), "# found\n")

        workspace = HColumns::Workspace.new(graph: HColumns::Graph.new,
                                            providers: [HColumns::Providers::Filesystem.new])
        root = workspace.add_node(HColumns::Providers::Filesystem.node_for(dir))

        matches = described_class.new(workspace, now: now).find("needle", from: root.id)
        expect(matches.map { |n| n.name.to_s }).to eq(["needle.rb"])
      end
    end
  end
end
