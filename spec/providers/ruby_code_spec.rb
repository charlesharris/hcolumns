# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe HColumns::Providers::RubyCode do
  def now = FIXED_NOW

  # A tiny two-file "project": lib/shop/order.rb defines Shop::Order (which
  # require_relative's item and references Shop::Item), and lib/shop/item.rb
  # defines Shop::Item.
  around do |example|
    Dir.mktmpdir("hcol-ruby") do |dir|
      @root = File.realpath(dir)
      write "lib/shop/item.rb", <<~RB
        module Shop
          class Item
            def price = 0
          end
        end
      RB
      write "lib/shop/order.rb", <<~RB
        require_relative "item"

        module Shop
          class Order
            def total
              Item.new
            end

            def self.build = new
          end
        end
      RB
      example.run
    end
  end

  def write(rel, contents)
    abs = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(abs))
    File.write(abs, contents)
  end

  def workspace
    @workspace ||= HColumns::Workspace.new(providers: [
      HColumns::Providers::Filesystem.new,
      described_class.new(@root)
    ])
  end

  def node_for(rel)
    workspace.add_node(HColumns::Providers::Filesystem.node_for(File.join(@root, rel)))
  end

  def column_for(rel)
    workspace.column_for(node_for(rel).id, now: now)
  end

  def group(column, relation)
    column.groups.find { |g| g.relation == relation }
  end

  it "DEFINES the class a file declares (the most specific const)" do
    defines = group(column_for("lib/shop/order.rb"), :DEFINES)
    expect(defines.entries.map { |e| e.target.name }).to eq(["Order"])
    expect(defines.entries.first.target.properties[:qualified_name]).to eq("Shop::Order")
  end

  it "DEPENDS_ON a require_relative that resolves to a real file" do
    deps = group(column_for("lib/shop/order.rb"), :DEPENDS_ON)
    expect(deps.entries.map { |e| e.target.name }).to eq(["item.rb"])
  end

  it "REFERENCES a constant defined in another file" do
    refs = group(column_for("lib/shop/order.rb"), :REFERENCES)
    expect(refs.entries.map { |e| e.target.properties[:qualified_name] }).to eq(["Shop::Item"])
  end

  it "marks require_relative as structure but a cross-file reference as inference" do
    order = column_for("lib/shop/order.rb")
    dep = group(order, :DEPENDS_ON).entries.first
    ref = group(order, :REFERENCES).entries.first
    expect(dep.edge.evidence_kinds).to eq([:structure])
    expect(ref.edge.evidence_kinds).to eq([:inference])
  end

  it "walks INTO a class to its methods and a DEFINED_IN back-edge" do
    order_file = column_for("lib/shop/order.rb")
    order_const = group(order_file, :DEFINES).entries.first.target

    column = workspace.column_for(order_const.id, now: now)
    methods = group(column, :DEFINES).entries.map { |e| e.target.name }
    expect(methods).to contain_exactly("#total", ".build")
    expect(group(column, :DEFINED_IN).entries.map { |e| e.target.name }).to eq(["order.rb"])
  end

  it "does nothing for a non-ruby or out-of-root node" do
    write "notes.txt", "hello"
    expect(described_class.new(@root).recognizes?(node_for("notes.txt"))).to be(false)
  end
end
