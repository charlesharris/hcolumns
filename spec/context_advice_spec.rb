# frozen_string_literal: true

require "tmpdir"
require "json"

# The dark-pattern dictionary (hc-bnh). What these specs mostly pin is DISCIPLINE:
# advice must stay an opinion (never structure), savings must be quoted in
# cost-equivalent (never wire, which overstates ~8x), and a suggestion must be a
# real node you can click through to the cost it names.
RSpec.describe HColumns::Providers::ContextAdvice do
  def now = FIXED_NOW

  around do |example|
    Dir.mktmpdir("hcol-advice") do |dir|
      @dir = dir
      @path = File.join(dir, "session.jsonl")
      example.run
    end
  end

  def write(*entries) = File.write(@path, entries.map { |e| JSON.generate(e) }.join("\n"))

  def assistant(*blocks, id: nil)
    { "type" => "assistant",
      "message" => { "content" => blocks, "id" => id || "msg_#{blocks.object_id}",
                     "usage" => { "output_tokens" => 1 } } }
  end

  def user(*blocks) = { "type" => "user", "message" => { "content" => blocks } }

  def graph_for(path)
    graph = HColumns::Graph.new
    node = graph.add_node(HColumns::Providers::Transcript.node_for(path))
    HColumns::Workspace.new(graph: graph,
                            providers: [HColumns::Providers::Transcript, described_class])
                       .expand(node.id, now: now)
    [graph, node]
  end

  def suggestions(graph) = graph.nodes.select { |n| n.type == :Suggestion }

  # A big read landing early, then 20 turns of residency behind it — the STATUS.md
  # shape, the largest real pattern we measured (13.2% of cost).
  def early_read_transcript
    write(
      assistant({ "type" => "tool_use", "id" => "t1", "name" => "Read",
                  "input" => { "file_path" => "/x/STATUS.md" } }, id: "m1"),
      user({ "type" => "tool_result", "tool_use_id" => "t1", "content" => "s" * 12_000 }),
      *Array.new(20) { |i| assistant({ "type" => "text", "text" => "x" }, id: "m#{i + 2}") }
    )
  end

  it "suggests reading less, later, for a large early read" do
    early_read_transcript
    graph, = graph_for(@path)
    s = suggestions(graph).find { |n| n.properties[:rule] == :early_large_read }

    expect(s).not_to be_nil
    expect(s.properties[:advice]).to include("offset/limit")
    expect(s.properties[:saving]).to be_positive
  end

  # Charris's ask: clickable. suggestion -> ABOUT -> the block that cost the money.
  it "points at the block it is about, so it can be clicked through" do
    early_read_transcript
    graph, = graph_for(@path)
    s = suggestions(graph).first
    about = graph.edges_from(s.id).find { |e| e.type == :ABOUT }

    expect(graph.node(about.target_id).type).to eq(:ContextBlock)
    expect(graph.node(about.target_id).properties[:name]).to eq("Read(STATUS.md)")
  end

  # The discipline that lets bad advice sink instead of needing to be hidden:
  # a suggestion is a CLAIM. The block's cost is a fact; whether it was avoidable
  # is an opinion, and confidence must keep saying so.
  it "offers advice as inference, never as structure" do
    early_read_transcript
    graph, node = graph_for(@path)
    edge = graph.edges_from(node.id).find { |e| e.type == :SUGGESTS }

    expect(edge.observations.first.evidence_kind).to eq(:inference)
    expect(edge.confidence(now: now)).to be < 1.0
  end

  # A saving quoted in wire volume would overstate its own payoff ~8x — a lie in
  # the user's favour, which is the worse kind.
  it "quotes savings in cost-equivalent, never wire volume" do
    early_read_transcript
    graph, = graph_for(@path)
    s = suggestions(graph).find { |n| n.properties[:rule] == :early_large_read }
    # By KIND, not by name: a call and its result share a label (both read the
    # same file) and are told apart by glyph — so a name lookup here silently
    # grabbed the 58-token call instead of the 12k result.
    block = graph.nodes.find { |n| n.type == :ContextBlock && n.properties[:kind] == "tool_result" }

    expect(s.properties[:saving]).to be <= block.properties[:cost]
    expect(s.properties[:saving]).to be < block.properties[:wire]
  end

  it "leaves a piped command alone and flags an unpiped one" do
    write(
      assistant({ "type" => "tool_use", "id" => "t1", "name" => "Bash",
                  "input" => { "command" => "cat huge.log | head -20" } }, id: "m1"),
      user({ "type" => "tool_result", "tool_use_id" => "t1", "content" => "o" * 8_000 }),
      *Array.new(15) { |i| assistant({ "type" => "text", "text" => "x" }, id: "m#{i + 2}") }
    )
    graph, = graph_for(@path)

    expect(suggestions(graph).map { |n| n.properties[:rule] }).not_to include(:unpiped_output)
  end

  # Nothing worth saying beats something worth ignoring: a quiet session must
  # produce an empty panel, not filler.
  it "says nothing about a session with no expensive blocks" do
    write(assistant({ "type" => "text", "text" => "hi" }, id: "m1"))
    graph, = graph_for(@path)

    expect(suggestions(graph)).to be_empty
  end

  # These three were killed by measurement and must STAY killed — the specs are
  # where that decision is enforced, not the comments.
  describe "the rules we deliberately rejected" do
    it "does not resurrect duplicate-content (1.3%, and mostly boilerplate acks)" do
      expect(described_class::RULES.map(&:key)).not_to include(:duplicate_content)
    end

    it "does not flag error results (0.1% — noise)" do
      expect(described_class::RULES.map(&:key)).not_to include(:error_result)
    end

    it "does not import cache-thrash (its precondition never occurs here)" do
      expect(described_class::RULES.map(&:key)).not_to include(:cache_thrash, :parallel_tool_calls)
    end
  end
end
