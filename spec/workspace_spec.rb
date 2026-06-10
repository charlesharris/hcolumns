# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe HColumns::Workspace do
  now = FIXED_NOW

  # A small real tree on disk for the on-demand filesystem provider to walk.
  around do |example|
    Dir.mktmpdir("hcol") do |dir|
      @root = dir
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "orders.rb"), "x")
      File.write(File.join(dir, "src", "orders_spec.rb"), "x")
      File.write(File.join(dir, "README.md"), "x")
      FileUtils.mkdir_p(File.join(dir, ".git")) # must be ignored
      example.run
    end
  end

  def workspace
    @workspace ||= HColumns::Workspace.new(
      providers: [HColumns::Providers::Filesystem.new, HColumns::Providers::NamingRules.new]
    ).tap { |w| @root_id = w.add_node(HColumns::Providers::Filesystem.node_for(@root)).id }
  end

  def id_for(*parts)
    abspath = File.expand_path(File.join(@root, *parts))
    HColumns::Identity.id_for(scheme: "fs.path", key: "local:#{abspath}")
  end

  it "loads the root's children on first column, skipping hidden/ignored entries" do
    names = workspace.column_for(@root_id, now: now).entries.map { |e| e.target.name }
    expect(names).to include("src", "README.md")
    expect(names).not_to include(".git")
  end

  it "is lazy: a subdirectory's children are not loaded until its column is requested" do
    workspace.column_for(@root_id, now: now)
    expect(workspace.node(id_for("src", "orders.rb"))).to be_nil # not yet

    column = workspace.column_for(id_for("src"), now: now)
    expect(column.entries.map { |e| e.target.name }).to include("orders.rb", "orders_spec.rb")
    expect(workspace.node(id_for("src", "orders.rb"))).not_to be_nil
  end

  it "pairs a source file with its co-located spec via the naming rule" do
    workspace.column_for(@root_id, now: now)
    workspace.column_for(id_for("src"), now: now)

    pair = workspace.column_for(id_for("src", "orders.rb"), now: now)
               .groups.find { |g| g.relation == :PAIR }
    expect(pair).not_to be_nil
    expect(pair.entries.map { |e| e.target.name }).to eq(["orders_spec.rb"])
  end

  it "expands each node at most once, so confidence does not inflate on revisits" do
    first = workspace.column_for(@root_id, now: now).entries.first.confidence
    second = workspace.column_for(@root_id, now: now).entries.first.confidence
    expect(second).to eq(first)
  end

  it "serves a pre-folded graph unchanged when given no providers" do
    graph = HColumns::Providers::InMemoryFixture.build(now: now)
    ws = described_class.new(graph: graph)
    orders = HColumns::Providers::InMemoryFixture.orders_id
    expect(ws.column_for(orders, now: now).groups.map(&:relation)).to include(:PAIR, :CO_CHANGED_WITH)
  end
end
