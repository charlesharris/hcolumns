# frozen_string_literal: true

require "tmpdir"
require "json"

# The context stratum (hc-33x): a session's raw transcript as cost-ranked blocks.
# These specs pin the two things the feature lives or dies on — that cost is
# size x RESIDENCY (not size), and that a result is legible at all (which needs
# the tool_use correlation) — plus the discipline that keeps it honest: an
# estimated cost is :inference, and the text never enters the graph.
RSpec.describe HColumns::Providers::Transcript do
  def now = FIXED_NOW

  around do |example|
    Dir.mktmpdir("hcol-transcript") do |dir|
      @dir = dir
      @path = File.join(dir, "session.jsonl")
      example.run
    end
  end

  # A miniature transcript in Claude Code's shape. Each assistant entry with a
  # usage block is one billed turn — the same boundary the hook's slice uses.
  def write_transcript(*entries)
    File.write(@path, entries.map { |e| JSON.generate(e) }.join("\n"))
  end

  def assistant(*blocks, usage: true)
    { "type" => "assistant",
      "message" => { "content" => blocks }.merge(usage ? { "usage" => { "output_tokens" => 1 } } : {}) }
  end

  def user(*blocks) = { "type" => "user", "message" => { "content" => blocks } }

  def tool_use(id, name, input) = { "type" => "tool_use", "id" => id, "name" => name, "input" => input }

  def tool_result(id, text) = { "type" => "tool_result", "tool_use_id" => id, "content" => text }

  def thinking(text) = { "type" => "thinking", "thinking" => text }

  def graph_with(path)
    graph = HColumns::Graph.new
    node = graph.add_node(described_class.node_for(path))
    HColumns::Workspace.new(graph: graph, providers: [described_class]).expand(node.id, now: now)
    [graph, node]
  end

  def blocks_of(graph, node)
    graph.edges_from(node.id).select { |e| e.type == :CONSUMED }
         .map { |e| graph.node(e.target_id) }.sort_by { |n| -n.properties[:cost] }
  end

  # The finding the whole design rests on: a small block that lands EARLY can
  # outcost a much larger one that lands late, because every later turn re-sends
  # it. Measured on a real session: 14.5k tokens read at turn 8 stayed resident
  # 531 turns and outcost a block twice its size by 6x.
  #
  # But there is a CROSSOVER, and cache pricing sets it: a block is written once
  # at 1.25x and re-read at only 0.1x, so residency has to overcome the write
  # premium before it dominates size. At a 2.5x size gap the early block wins
  # after ~19 turns; at 10x it takes ~113. Below that, the bigger block really is
  # the more expensive one — which is why this fixture is deliberately over the
  # line rather than under it.
  it "ranks by size x residency, so a long-resident small block outcosts a late large one" do
    early = thinking("e" * 1600)         # ~400 tok, resident for the rest
    late  = thinking("l" * 4000)         # ~1000 tok, resident for nothing
    write_transcript(assistant(early), *Array.new(30) { assistant(thinking("x")) }, assistant(late))

    graph, node = graph_with(@path)
    top = blocks_of(graph, node).first
    last = blocks_of(graph, node).find { |b| b.properties[:turn] == 32 }

    expect(top.properties[:name]).to eq("thinking (turn 1)")
    expect(top.properties[:tokens]).to be < last.properties[:tokens] # smaller…
    expect(top.properties[:cost]).to be > last.properties[:cost]     # …yet dearer
  end

  # Wire volume is what crossed the network; cost-equivalent is what it was worth.
  # Across our own 12 sessions 98% of wire was cache reads at 0.1x, so reporting
  # wire as "billed" overstates the bill ~8x. Both numbers, or neither is honest.
  it "separates wire volume from cache-weighted cost" do
    write_transcript(assistant(thinking("x" * 4000)), *Array.new(9) { assistant(thinking("y")) })
    graph, node = graph_with(@path)
    block = blocks_of(graph, node).first
    p = block.properties

    expect(p[:wire]).to eq(p[:tokens] * (p[:resident] + 1))            # sent 10x
    expect(p[:cost]).to eq((p[:tokens] * (1.25 + (0.1 * p[:resident]))).round) # worth ~2.2x
    expect(p[:cost]).to be < p[:wire]
  end

  # A tool_result carries no input of its own — everything that makes it legible
  # lives on the call that caused it. Without this correlation the most expensive
  # rows in the view are all labelled "result" and anchor to nothing.
  it "labels a result from the call that produced it, not from the result block" do
    write_transcript(assistant(tool_use("t1", "Read", { "file_path" => "/tmp/x/STATUS.md" })),
                     user(tool_result("t1", "the file body")))

    graph, node = graph_with(@path)
    result = blocks_of(graph, node).find { |b| b.properties[:kind] == "tool_result" }

    expect(result.properties[:name]).to eq("Read(STATUS.md)")
    expect(result.properties[:file]).to eq("/tmp/x/STATUS.md")
  end

  # Charris's call: a Read's content is ALREADY an fs.path node, so point at it
  # rather than re-indexing its words. The payoff runs backwards — a file's
  # incoming edges then answer "this file cost me 7.7M".
  it "anchors a file-backed block to the real fs.path node" do
    file = File.join(@dir, "real.rb")
    File.write(file, "x = 1\n")
    write_transcript(assistant(tool_use("t1", "Read", { "file_path" => file })),
                     user(tool_result("t1", "x = 1")))

    graph, node = graph_with(@path)
    block = blocks_of(graph, node).find { |b| b.properties[:file] }
    HColumns::Workspace.new(graph: graph, providers: [described_class]).expand(block.id, now: now)
    reads = graph.edges_from(block.id).find { |e| e.type == :READS }

    expect(graph.node(reads.target_id).identity[:scheme]).to eq("fs.path") # unifies with fs/git/beads
    expect(reads.confidence(now: now)).to eq(1.0) # the read really happened
  end

  # A relative path would mint an fs.path node against the SERVING process's cwd,
  # which is not where the session ran — a wrong node is worse than no anchor.
  it "refuses to anchor a relative path" do
    write_transcript(assistant(tool_use("t1", "Read", { "file_path" => "lib/relative.rb" })),
                     user(tool_result("t1", "body")))

    graph, node = graph_with(@path)

    expect(blocks_of(graph, node).map { |b| b.properties[:file] }).to all(be_nil)
  end

  # The evidence discipline: the block's EXISTENCE is verifiable, but its cost is
  # a model (estimated tokens x residency). Confidence must keep reporting how much
  # we actually know — so the edge is :inference, and says "estimated" out loud.
  it "records an estimated cost as inference, never as structure" do
    write_transcript(assistant(thinking("hello")))
    graph, node = graph_with(@path)
    edge = graph.edges_from(node.id).find { |e| e.type == :CONSUMED }

    expect(edge.observations.first.evidence_kind).to eq(:inference)
    expect(edge.observations.first.evidence_summary).to include("estimated")
    expect(edge.confidence(now: now)).to be < 1.0
  end

  # The content-tab precedent (layers 21-24): a node's contents are read from the
  # world on demand, never folded in. A 2.8MB transcript must cost the graph KBs.
  it "keeps block text out of the graph, reading it back on demand" do
    write_transcript(assistant(thinking("the actual reasoning text")))
    graph, node = graph_with(@path)
    block = blocks_of(graph, node).first

    expect(block.properties.values.join).not_to include("the actual reasoning text")
    expect(described_class.text_for(block)).to eq(["the actual reasoning text"])
  end

  it "survives a corrupt line rather than failing the whole read" do
    File.write(@path, "#{JSON.generate(assistant(thinking('ok')))}\nnot json at all\n")
    graph, node = graph_with(@path)

    expect(blocks_of(graph, node).size).to eq(1)
  end

  # A subagent's blocks never entered THIS session's context, so billing them here
  # would attribute another context's cost to ours.
  it "skips sidechain entries" do
    write_transcript(assistant(thinking("mine")),
                     { "type" => "assistant", "isSidechain" => true,
                       "message" => { "content" => [thinking("subagent's")], "usage" => {} } })
    graph, node = graph_with(@path)

    expect(blocks_of(graph, node).map { |b| b.properties[:name] }).to eq(["thinking (turn 1)"])
  end
end
