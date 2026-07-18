# frozen_string_literal: true

require "tmpdir"

# Where the two halves of the dispatch bargain meet the strategy (hc-4s4, layer 34b):
# an isolated task runs IN its worktree, and every start and every ending leaves a
# record. tmux is stubbed here on purpose — spec/worktrees_spec.rb already exercises
# real git, and what is under test at this level is the WIRING: which directory the
# pane is opened in, and whether the audit points survive a refactor.
RSpec.describe HColumns::Strategies::TmuxClaudeCode do
  around { |ex| Dir.mktmpdir("hcol-isolation") { |d| @root = d; ex.run } }

  let(:audit) { HColumns::Audit.new(path: File.join(@root, "audit.jsonl")) }
  let(:worktrees) { instance_double(HColumns::Worktrees) }
  let(:task) { HColumns::LLMTaskRunner::Task.new(key: "abc123", prompt: "fix the thing", request_id: "live:r1") }

  # Every tmux invocation the strategy makes, so a test can ask what it actually ran.
  def calls = @calls ||= []

  def strategy(**over)
    described_class.new(root: @root, audit: audit, **over).tap do |s|
      allow(s).to receive(:tmux) { |*args| calls << args; ["", nil] }
      allow(s).to receive(:resolve_pane).and_return("hcol-abc123:0.0")
      allow(s).to receive(:start_pipe)
      allow(described_class).to receive(:trusted?).and_return(true)
    end
  end

  def spawn_call = calls.find { |c| c.first == "new-session" }

  describe "worktree isolation" do
    before do
      allow(worktrees).to receive(:ensure).with("abc123").and_return(File.join(@root, ".git/hcolumns/worktrees/abc123"))
      allow(worktrees).to receive(:path_for).with("abc123").and_return(File.join(@root, ".git/hcolumns/worktrees/abc123"))
      allow(worktrees).to receive(:branch_for).with("abc123").and_return("hcol/abc123")
    end

    it "opens the pane IN the worktree, not in the repo the human is sitting in" do
      strategy(worktrees: worktrees).start(task)

      expect(spawn_call).to include("-c", File.join(@root, ".git/hcolumns/worktrees/abc123"))
      expect(spawn_call).not_to include(@root)
    end

    it "runs in place when no worktrees are configured — the historical behaviour" do
      strategy.start(task)

      expect(spawn_call).to include("-c", @root)
    end

    # The task's own records have to outlive a worktree that gets removed, and
    # adopt/2 has to find them from the key without knowing which tree ran it.
    it "keeps the task log under the main repo, not inside the worktree" do
      handle = strategy(worktrees: worktrees).start(task)

      expect(handle.log).to eq(File.join(@root, ".hcolumns", "tasks", "abc123.jsonl"))
    end

    # Adopting must not resurrect a tree a cleanup already removed — it reports
    # where the tree WAS, which is what the audit record wants either way.
    it "derives the worktree on adopt without re-creating it" do
      handle = strategy(worktrees: worktrees).adopt("abc123")

      expect(handle.branch).to eq("hcol/abc123")
      expect(worktrees).not_to have_received(:ensure)
    end
  end

  describe "the audit trail" do
    it "records the spawn BEFORE the pane exists, so a wedge on first breath still leaves a trace" do
      strategy(origin: "ui").start(task)

      record = audit.entries.find { |e| e[:event] == "dispatch.spawn" }
      expect(record).to include(key: "abc123", origin: "ui", request_id: "live:r1",
                                prompt: "fix the thing", command: described_class::DEFAULT_COMMAND)
    end

    # The question the log exists to answer: this ran because someone clicked in a
    # browser, and that is a property you can grep for rather than infer.
    it "marks who asked" do
      strategy(origin: "ui").start(task)
      expect(audit.entries.map { |e| e[:origin] }).to all(eq("ui"))
    end

    it "defaults to a cli origin" do
      strategy.start(task)
      expect(audit.entries.first[:origin]).to eq("cli")
    end

    it "records a terminal outcome once the task ends" do
      s = strategy
      handle = s.start(task)
      allow(s).to receive(:poll_result).and_return({ status: :done, response: "did it" })

      s.poll(handle)

      expect(audit.entries.last).to include(event: "dispatch.outcome", status: "done", response: "did it")
    end

    it "stays quiet while the task is still running" do
      s = strategy
      handle = s.start(task)
      allow(s).to receive(:poll_result).and_return(:running)

      s.poll(handle)

      expect(audit.entries.map { |e| e[:event] }).not_to include("dispatch.outcome")
    end

    # The agent's prose is a claim; the sha and the diffstat are the record.
    it "records what git says the agent did, not only what the agent said" do
      allow(worktrees).to receive_messages(ensure: File.join(@root, "wt"), branch_for: "hcol/abc123",
                                           head: "deadbeef" * 5, diffstat: "2 files changed, 9 insertions(+)",
                                           commits: [{ sha: "deadbeef" * 5, subject: "agent commit" }])
      s = strategy(worktrees: worktrees)
      handle = s.start(task)
      allow(s).to receive(:poll_result).and_return({ status: :done, response: "I fixed everything" })

      s.poll(handle)

      expect(audit.entries.last).to include(head: "deadbeef" * 5, diffstat: "2 files changed, 9 insertions(+)",
                                            branch: "hcol/abc123")
    end

    it "does not fail a finished task because a repo question failed" do
      allow(worktrees).to receive_messages(ensure: File.join(@root, "wt"), branch_for: "hcol/abc123")
      allow(worktrees).to receive(:head).and_raise(HColumns::Worktrees::Error, "repo gone")
      s = strategy(worktrees: worktrees)
      handle = s.start(task)
      allow(s).to receive(:poll_result).and_return({ status: :done, response: "did it" })

      expect { s.poll(handle) }.not_to raise_error
      expect(audit.entries.last).to include(status: "done", repo_error: "repo gone")
    end
  end
end
