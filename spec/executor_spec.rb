# frozen_string_literal: true

require "tmpdir"

# The execute half of the UI-dispatch hop (hc-4s4, layer 34c). The Dispatcher queues;
# this puts an agent on it. Exercised with the Echo strategy — the whole point of the
# double is that the dispatch loop is specifiable with no LLM, no tokens and no tmux.
RSpec.describe HColumns::Executor do
  around do |ex|
    Dir.mktmpdir("hcol-exec") do |d|
      @dir = d
      @log = File.join(d, "live.jsonl")
      FileUtils.touch(@log) # a serve tails an existing log; an empty one is the honest starting state
      ex.run
    end
  end

  let(:audit) { HColumns::Audit.new(path: File.join(@dir, "audit.jsonl")) }
  let(:runner) { HColumns::LLMTaskRunner.new(strategy: HColumns::Strategies::Echo.new, log: @log, session: "live") }
  subject(:executor) { described_class.new(runner: runner, audit: audit) }

  def dispatcher = HColumns::Dispatcher.new(log: @log, session: "live")
  def graph = File.open(@log) { |io| HColumns::Persistence.load(io) }.project
  def tasks(g = graph) = g.nodes.select { |n| n.type == :LLMTask }

  it "puts a task on a Request that was queued from the browser" do
    dispatcher.ask("fix the flaky spec")

    executor.advance(graph)

    expect(tasks.size).to eq(1)
    expect(tasks.first.properties[:request_id]).to eq(graph.nodes.find { |n| n.type == :Request }.id)
  end

  # Outstanding is a question for the GRAPH, so this falls out rather than needing a
  # cursor: the request already has a task, so a second frame finds nothing to do.
  it "does not re-fire a request it has already dispatched" do
    dispatcher.ask("fix the flaky spec")
    executor.advance(graph)

    expect { executor.advance(graph) }.not_to change { tasks.size }
  end

  it "reports nothing to do on an empty log" do
    expect(executor.advance(graph)).to eq(0)
  end

  # The browser is a read surface FIRST. A dispatch that explodes must fail its task
  # and leave the viewer working, not take the page down with it.
  it "never raises into the request path" do
    allow(runner).to receive(:submit_outstanding).and_raise(StandardError, "tmux is gone")
    dispatcher.ask("something")

    expect { executor.advance(graph) }.not_to raise_error
    expect(audit.entries.last).to include(event: "dispatch.error", message: "tmux is gone")
  end

  it "settles stranded work once, not on every frame" do
    allow(runner).to receive(:reconcile).and_return(0)

    3.times { executor.advance(graph) }

    expect(runner).to have_received(:reconcile).once
  end

  describe "#retry_task" do
    it "records a ui-origin retry" do
      allow(runner).to receive(:retry).and_return(%w[newkey])

      expect(executor.retry_task(graph, "oldkey")).to include(ok: true, retried: "oldkey")
      expect(audit.entries.last).to include(event: "dispatch.retry", origin: "ui", key: "oldkey")
    end

    it "returns nil when there is nothing to retry, so the router can 404 it" do
      allow(runner).to receive(:retry).and_return([])

      expect(executor.retry_task(graph, "oldkey")).to be_nil
    end
  end

  describe "#review" do
    let(:worktrees) { instance_double(HColumns::Worktrees) }
    subject(:executor) { described_class.new(runner: runner, worktrees: worktrees, audit: audit) }

    it "surfaces the branch a finished task left behind — it does not merge it" do
      allow(worktrees).to receive_messages(branch_for: "hcol/abc", branch?: true, head: "deadbeef",
                                           diffstat: "1 file changed", commits: [{ sha: "deadbeef", subject: "fix" }])

      expect(executor.review("abc")).to include(branch: "hcol/abc", diffstat: "1 file changed")
    end

    it "is nil when the task never cut a branch" do
      allow(worktrees).to receive_messages(branch_for: "hcol/abc", branch?: false)

      expect(executor.review("abc")).to be_nil
    end

    it "is nil without worktrees — nothing was isolated, so there is nothing to review" do
      expect(described_class.new(runner: runner).review("abc")).to be_nil
    end
  end
end
