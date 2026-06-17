# frozen_string_literal: true

RSpec.describe HColumns::Cascade do
  now = FIXED_NOW
  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:source) { HColumns::Workspace.new(graph: graph) }
  let(:repo) { graph.nodes.find { |n| n.name == "repo/" }.id }
  subject(:cascade) { described_class.new(source, repo, now: now) }

  # Put the active cursor on the item labeled `name`.
  def nav_to(name)
    idx = cascade.active_entries.index { |e| e.label == name }
    raise "no entry for #{name.inspect}" unless idx

    cascade.active.cursor = idx
  end

  it "starts at the root with a single frame" do
    expect(cascade.depth).to eq(1)
    expect(cascade.current_node.name).to eq("repo/")
    expect(cascade.active.cursor).to eq(0)
  end

  it "moves the cursor within the active column, clamped at both ends" do
    cascade.up
    expect(cascade.active.cursor).to eq(0)

    cascade.down
    expect(cascade.active.cursor).to eq(1)

    100.times { cascade.down }
    expect(cascade.active.cursor).to eq(cascade.active_entries.length - 1)
  end

  it "descends into the selected target and pops back" do
    nav_to("src")
    cascade.into
    expect(cascade.depth).to eq(2)
    expect(cascade.current_node.name).to eq("src")

    cascade.back
    expect(cascade.depth).to eq(1)
    expect(cascade.current_node.name).to eq("repo/")
  end

  it "never pops past the root" do
    cascade.back
    expect(cascade.depth).to eq(1)
  end

  it "walks repo › src › orders.rb, recording the trail" do
    nav_to("src")
    cascade.into
    nav_to("src/orders.rb")
    cascade.into

    expect(cascade.current_node.name).to eq("src/orders.rb")
    expect(cascade.trail.map(&:name)).to eq(["repo/", "src", "src/orders.rb"])
  end

  it "previews the active selection's target under its own auto mode, without walking in" do
    nav_to("src")
    expect(cascade.preview_panel.node.name).to eq("src")
    expect(cascade.depth).to eq(1) # preview does not push a frame
  end

  it "previews a leaf as its details facet rather than an empty pane" do
    nav_to("src")
    cascade.into
    nav_to("src/payments.rb") # a node with no outgoing relations
    preview = cascade.preview_panel
    expect(preview.empty?).to be false
    expect(preview.sections.map(&:heading)).to include("NODE")
  end

  it "treats a node with no outgoing relations as a leaf" do
    nav_to("src")
    cascade.into
    nav_to("src/payments.rb") # only an incoming co-change target
    cascade.into
    expect(cascade.active_panel).to be_empty
    expect(cascade.selected_entry).to be_nil
  end
end
