# frozen_string_literal: true

# The debugging phase's point (hc-4s4): arriving at a red test should hand you the
# ASSERTION, not the run. These use real output shapes from four different runners,
# because the design claim is that the heuristic keys on SHAPE rather than vendor —
# and a claim like that is only worth anything if it is tested against runners nobody
# wrote a branch for.
RSpec.describe HColumns::FailureMode do
  subject(:mode) { described_class.new }

  def test_run(output, state: "failed", type: :TestRun)
    HColumns::Node.new(type: type, identity: { scheme: "agent.test", key: "live:t1" },
                       properties: { name: "✗ bundle exec rspec", state: state, output: output })
  end

  def panel_for(node) = mode.panel(node, nil, now: Time.now)
  def headings(node) = panel_for(node).sections.map(&:heading)
  def lines_under(node, heading) = panel_for(node).sections.find { |s| s.heading == heading }&.lines || []

  RSPEC = <<~OUT
    ..F

    Failures:

      1) Worktrees#ensure creates a checkout on its own branch
         Failure/Error: expect(git("rev-parse")).to eq("hcol/abc")

           expected: "hcol/abc"
                got: "main"

         # ./spec/worktrees_spec.rb:41:in 'block (3 levels)'
         # ./spec/worktrees_spec.rb:13:in 'block (2 levels)'

    Finished in 0.96 seconds
    21 examples, 1 failure
  OUT

  PYTEST = <<~OUT
    =================== FAILURES ===================
    ___________________ test_add ___________________

        def test_add():
    >       assert add(2, 2) == 5
    E       AssertionError: assert 4 == 5

    tests/test_math.py:7: AssertionError
  OUT

  MINITEST = <<~OUT
    Failure:
    TestMath#test_add [test/test_math.rb:12]:
    Expected: 5
      Actual: 4
  OUT

  describe "#applies?" do
    it "applies to a failed run" do
      expect(mode.applies?(test_run(RSPEC))).to be true
    end

    it "does NOT apply to a passing run — there is no failure to foreground" do
      green = test_run(["21 examples, 0 failures"], state: "done")
      expect(mode.applies?(green)).to be false
    end

    # State is the strong signal, but output that plainly contains a failure should
    # not be hidden because a state property was never set.
    it "applies when the output is marked even if no state says so" do
      expect(mode.applies?(test_run(PYTEST, state: nil))).to be true
    end

    it "ignores nodes that carry no output at all" do
      expect(mode.applies?(HColumns::Node.new(type: :SourceFile, identity: { scheme: "fs.path", key: "a.rb" }))).to be false
    end
  end

  describe "foregrounding the assertion" do
    it "leads with why it failed, not with the run" do
      expect(headings(test_run(RSPEC)).first).to eq("WHY IT FAILED")
      expect(lines_under(test_run(RSPEC), "WHY IT FAILED").join("\n")).to include("Failure/Error")
    end

    it "pulls the expected/actual pair out — the sentence a human actually reads" do
      pair = lines_under(test_run(RSPEC), "EXPECTED / ACTUAL").join("\n")

      expect(pair).to include("hcol/abc").and include("main")
    end

    it "surfaces where to go next" do
      expect(lines_under(test_run(RSPEC), "WHERE")).to include("./spec/worktrees_spec.rb:41")
    end

    it "leaves out the run chrome the assertion was buried in" do
      shown = panel_for(test_run(RSPEC)).sections.flat_map(&:lines).join("\n")

      expect(shown).not_to include("21 examples, 1 failure")
    end
  end

  # The load-bearing design claim: shape, not vendor. No branch was written for any
  # of these runners, and there is no per-tool table to keep current.
  describe "runners nobody wrote a branch for" do
    it "reads pytest" do
      node = test_run(PYTEST)

      expect(lines_under(node, "WHY IT FAILED").join("\n")).to include("AssertionError")
      expect(lines_under(node, "WHERE")).to include("tests/test_math.py:7")
    end

    it "reads minitest" do
      node = test_run(MINITEST)

      expect(lines_under(node, "EXPECTED / ACTUAL").join("\n")).to include("Actual: 4")
      expect(lines_under(node, "WHERE")).to include("test/test_math.rb:12")
    end

    it "reads a jest-style failure" do
      node = test_run("● adds numbers\n\n  expect(received).toBe(expected)\n\n  Expected: 5\n  Received: 4\n")

      expect(lines_under(node, "EXPECTED / ACTUAL").join("\n")).to include("Received: 4")
    end
  end

  describe "when the output is not recognisable" do
    # Degrade to "here's the tail", never to an empty panel and never to a guess.
    it "still shows something for a failed run it cannot parse" do
      node = test_run(["the build died", "no idea why"], state: "failed")

      expect(headings(node)).to eq(["OUTPUT (tail)"])
      expect(lines_under(node, "OUTPUT (tail)")).to include("no idea why")
    end
  end

  describe "a run with several failures" do
    it "shows the first one whole rather than two halves" do
      two = test_run("Failure: first thing broke\n  detail A\nFailure: second thing broke\n  detail B\n")
      shown = lines_under(two, "WHY IT FAILED").join("\n")

      expect(shown).to include("first thing broke").and include("detail A")
      expect(shown).not_to include("second thing broke")
    end
  end
end
