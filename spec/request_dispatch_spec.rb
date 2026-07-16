# frozen_string_literal: true

require "tmpdir"

# The connector (hc-4s4): the log carries intent, the runner puts an LLM on it.
#
# The property under test is that dispatch is GENERIC. `hcol fix` and `hcol ask`
# write the same Request; the runner cannot tell them apart, and must never learn
# to. A fix is only a request whose prompt came from a suggestion.
RSpec.describe "request dispatch" do
  around do |example|
    Dir.mktmpdir("hcol-dispatch") do |dir|
      @log = File.join(dir, "live.jsonl")
      example.run
    end
  end

  def bridge = HColumns::AgentBridge.new(path: @log, session: "s1", clock: -> { FIXED_NOW })

  def graph = File.open(@log) { |io| HColumns::Persistence.load(io) }.project

  def runner
    HColumns::LLMTaskRunner.new(strategy: HColumns::Strategies::Echo.new, log: @log,
                                clock: -> { FIXED_NOW })
  end

  def outstanding = HColumns::LLMTaskRunner.outstanding(graph)

  it "dispatches requests of any provenance through one path" do
    bridge.apply("request ask - explain the tuner")
    bridge.apply("request fix obj:abc pipe this through head")

    expect(outstanding.map { |r| r.properties[:kind] }).to contain_exactly(:ask, :fix)
  end

  # The whole reason dispatch lives outside the log: a walk replays it, and work
  # must not re-fire from a snapshot weeks later. Asking the GRAPH — a request
  # with no task — makes that fall out of the fold rather than out of a cursor
  # file somebody has to keep in sync.
  it "is replay-safe: a dispatched request stops being outstanding" do
    bridge.apply("request ask - explain the tuner")
    expect(outstanding.size).to eq(1)

    r = runner
    r.submit_outstanding(graph)
    r.poll

    expect(outstanding).to be_empty       # in this process…
    expect(HColumns::LLMTaskRunner.outstanding(graph)).to be_empty # …and after a full replay
  end

  it "links the task back to the request that asked for it" do
    bridge.apply("request ask - explain the tuner")
    request = outstanding.first
    r = runner
    r.submit_outstanding(graph)

    task = graph.nodes.find { |n| n.type == :LLMTask }
    expect(task.properties[:request_id]).to eq(request.id)
  end

  # Provenance is for a human reading the column, not for dispatch — but it has to
  # actually reach the graph, or a fix would be unmoored from its suggestion.
  it "points a fix at the node it concerns, and an ask at nothing" do
    bridge.apply("request fix obj:sugg1 pipe this through head")
    bridge.apply("request ask - explain the tuner")

    fix = graph.nodes.find { |n| n.properties[:kind] == :fix }
    ask = graph.nodes.find { |n| n.properties[:kind] == :ask }

    expect(graph.edges_from(fix.id).map(&:target_id)).to eq(["obj:sugg1"])
    expect(graph.edges_from(ask.id)).to be_empty # "-" is not a node; a dangling edge would lie
  end

  # A request is a FACT — someone asked, at a time. Facts don't get rewritten, so
  # a retry is a second task, not an edited request.
  it "keeps the request immutable and puts the state on the task" do
    bridge.apply("request ask - explain the tuner")
    request = outstanding.first

    expect(request.properties).not_to have_key(:state)
    r = runner
    r.submit_outstanding(graph)
    r.poll
    expect(graph.nodes.find { |n| n.type == :LLMTask }.properties[:state]).to eq(:done)
  end
end
