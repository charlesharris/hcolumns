# frozen_string_literal: true

require "tmpdir"

# The LLM task runner (hc-4s4) — fire a request at a model, get the answer back
# as a node. These specs drive the runner against the Echo double, so the whole
# lifecycle (pending → running → done/failed, timeouts, a strategy that throws)
# is pinned with no LLM, no network and no tmux. That is the point of the seam:
# if a strategy can only be tested by talking to a model, it can't be tested.
RSpec.describe HColumns::LLMTaskRunner do
  def now = FIXED_NOW

  around do |example|
    Dir.mktmpdir("hcol-runner") do |dir|
      @log = File.join(dir, "live.jsonl")
      example.run
    end
  end

  def runner(strategy)
    described_class.new(strategy: strategy, log: @log, clock: -> { now })
  end

  def graph = File.open(@log) { |io| HColumns::Persistence.load(io) }.project

  def task_node = graph.nodes.find { |n| n.type == :LLMTask }

  def echo(**opts) = HColumns::Strategies::Echo.new(**opts)

  it "gives the task a node before the work happens, not after" do
    # A strategy that never finishes: the node must still exist, and be visible
    # as in-flight — a task you can only see once it's done is a receipt, not a
    # view of work.
    r = runner(echo(never_finish: ["t1"]))
    r.submit("summarize the tuner", key: "t1")

    expect(task_node.properties[:state]).to eq(:running)
    expect(task_node.properties[:name]).to include("summarize the tuner")
  end

  # The TestRun pattern: one digest-keyed node re-emitted per state, latest fold
  # wins — so a live walk shows ◌ → ◐ → ✓ flip IN PLACE rather than stacking up.
  it "flips one node through its states rather than piling up new ones" do
    r = runner(echo(answers: { "t1" => "the tuner scores edges" }))
    r.submit("summarize the tuner", key: "t1")
    r.poll

    expect(graph.nodes.count { |n| n.type == :LLMTask }).to eq(1)
    expect(task_node.properties[:state]).to eq(:done)
    expect(task_node.properties[:output].first).to include("the tuner scores edges")
  end

  it "returns the answer as a node the graph can reach" do
    r = runner(echo(answers: { "t1" => "42" }))
    r.submit("the question", key: "t1")
    r.poll

    change = graph.nodes.find { |n| n.type == :ProposedChange }
    edge = graph.edges_from(change.id).find { |e| e.type == :DISPATCHED }

    expect(graph.node(edge.target_id).type).to eq(:LLMTask)
    # :agent, not :structure — a model's answer is its account, not ground truth.
    expect(edge.observations.first.evidence_kind).to eq(:agent)
    expect(edge.confidence(now: now)).to be < 1.0
  end

  it "fails the task, not the runner, when a strategy refuses to start" do
    r = runner(echo(fail_on: ["t1"]))
    r.submit("doomed", key: "t1")

    expect(task_node.properties[:state]).to eq(:failed)
    expect(task_node.properties[:output].first).to include("echo refused")
  end

  it "fails the task, not the runner, when a strategy throws mid-flight" do
    strategy = Object.new
    def strategy.start(task) = task.key
    def strategy.poll(_h) = raise("pane vanished")
    def strategy.stop(_h) = nil

    r = runner(strategy)
    r.submit("doomed", key: "t1")
    r.poll

    expect(task_node.properties[:state]).to eq(:failed)
    expect(task_node.properties[:output].first).to include("pane vanished")
  end

  # The failure mode the prior art is known for: an agent stops to ask an
  # interactive question and the pane sits there forever. gastown shipped an
  # entire stuck-agent watchdog plugin for this. The runner's own wall-clock is
  # the backstop, independent of whatever the strategy believes.
  it "times out a task that never finishes" do
    r = runner(echo(never_finish: ["t1"]))
    r.submit("hangs forever", key: "t1")
    r.run_to_completion(timeout: 1, interval: 0.5, sleeper: ->(_s) {})

    expect(task_node.properties[:state]).to eq(:failed)
    expect(task_node.properties[:output].first).to include("timed out")
  end

  # Charris's call (hc-4s4): a permission prompt in a DETACHED pane is invisible —
  # the session wedges with no error and the runner learns nothing until its
  # wall-clock fires. Pinned as a spec because it is a deliberate safety
  # trade-off, not an incidental default: changing it should take saying so here.
  it "launches the agent with permissions skipped, because a prompt in a detached pane is invisible" do
    expect(HColumns::Strategies::TmuxClaudeCode::DEFAULT_COMMAND).to include("--dangerously-skip-permissions")
  end

  # Surviving the shell (hc-4s4): a runner dies with its terminal, but the agents it
  # spawned keep working in detached panes and finish on disk. The NEXT `hcol run`
  # reconciles — re-adopts what's still in flight and settles it, reaps what's done.
  describe "reconciling a prior run's stranded tasks" do
    # Stands in for the panes a dead runner left behind: adopt() rebuilds a handle
    # from the key, poll() reports whatever the disk now says, reap_orphans() records
    # which sessions it was asked to kill.
    def recovering_strategy(results: {}, reaped: [])
      strat = Object.new
      strat.instance_variable_set(:@results, results)
      strat.instance_variable_set(:@reaped, reaped)
      def strat.start(task) = task.key
      def strat.adopt(key) = key
      def strat.poll(handle) = @results.fetch(handle, :running)
      def strat.stop(_handle) = nil
      def strat.reap_orphans(keys) = @reaped.concat(keys)
      strat
    end

    it "re-adopts an in-flight task the previous runner never finished, and drives it home" do
      # First runner leaves t1 running and 'dies' — never polled to completion.
      runner(echo(never_finish: ["t1"])).submit("summarize the tuner", key: "t1")
      expect(task_node.properties[:state]).to eq(:running)

      # A fresh runner reconciles the graph and settles the adopted task.
      r2 = runner(recovering_strategy(results: { "t1" => { status: :done, response: "the tuner scores edges" } }))
      expect(r2.reconcile(graph)).to eq(1)
      r2.run_to_completion(timeout: 5, interval: 0.1, sleeper: ->(_s) {})

      expect(task_node.properties[:state]).to eq(:done)
      expect(task_node.properties[:output].first).to include("the tuner scores edges")
    end

    it "does not re-adopt a task that already finished, but reaps its leaked pane" do
      r = runner(echo(answers: { "t1" => "already answered" }))
      r.submit("q", key: "t1")
      r.poll # → done
      expect(task_node.properties[:state]).to eq(:done)

      reaped = []
      r2 = runner(recovering_strategy(reaped: reaped))
      expect(r2.reconcile(graph)).to eq(0)   # nothing in flight to adopt…
      expect(reaped).to eq(["t1"])           # …but the terminal task's pane is reaped
    end

    it "is a no-op for a strategy that cannot recover (the Echo double)" do
      runner(echo(never_finish: ["t1"])).submit("hangs", key: "t1")
      expect(runner(echo).reconcile(graph)).to eq(0)
    end
  end

  it "runs several tasks concurrently and settles them all" do
    r = runner(echo(answers: { "a" => "first", "b" => "second" }))
    r.submit("one", key: "a")
    r.submit("two", key: "b")
    r.run_to_completion(timeout: 5, interval: 0.1, sleeper: ->(_s) {})

    states = graph.nodes.select { |n| n.type == :LLMTask }.map { |n| n.properties[:state] }
    expect(states).to contain_exactly(:done, :done)
    expect(r).to be_done
  end
end
