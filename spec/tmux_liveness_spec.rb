# frozen_string_literal: true

# Stall detection and the process-tree reaper (hc-4s4). The completion event is
# what a HEALTHY task emits; these are the two mechanisms for the UNhealthy ones —
# a wedge that never emits, and the pane/process tree it leaves behind. Both are
# structured as pure functions of injectable readings, so the policy is pinned
# with no tmux, no real processes, and no wall-clock wait.
RSpec.describe HColumns::Strategies::TmuxClaudeCode do
  let(:strategy) { described_class.new(root: "/repo/x") }

  def at(seconds) = Time.at(1_000_000 + seconds)

  def handle(**over)
    described_class::Handle.new(
      { delivered: true, last_size: 0, last_activity: nil, last_progress_at: at(0) }.merge(over)
    )
  end

  describe "#stalled?" do
    it "does not trip while there is still time on the clock" do
      h = handle
      expect(strategy.stalled?(h, now: at(9), log_size: 0, activity_at: nil, timeout: 10)).to be false
    end

    it "trips once nothing has progressed for the whole timeout" do
      h = handle
      expect(strategy.stalled?(h, now: at(10), log_size: 0, activity_at: nil, timeout: 10)).to be true
    end

    it "resets the clock when the task log grows — a hook fired, that is real work" do
      h = handle(last_size: 100)
      # The log grew at t=8, so the quiet clock restarts there…
      strategy.stalled?(h, now: at(8), log_size: 140, activity_at: nil, timeout: 10)
      # …and one second later we are nowhere near stalled.
      expect(strategy.stalled?(h, now: at(9), log_size: 140, activity_at: nil, timeout: 10)).to be false
    end

    it "resets the clock when the pane redraws, covering Read-heavy work the log never sees" do
      h = handle(last_activity: 500)
      strategy.stalled?(h, now: at(8), log_size: 0, activity_at: 507, timeout: 10) # window_activity advanced
      expect(strategy.stalled?(h, now: at(9), log_size: 0, activity_at: 507, timeout: 10)).to be false
    end

    it "trips when BOTH signals are frozen — the genuine wedge (waiting on input)" do
      h = handle(last_size: 100, last_activity: 500)
      # Same log size, same activity stamp, across the whole timeout.
      strategy.stalled?(h, now: at(5),  log_size: 100, activity_at: 500, timeout: 10)
      expect(strategy.stalled?(h, now: at(10), log_size: 100, activity_at: 500, timeout: 10)).to be true
    end

    it "tolerates a missing activity reading, falling back to the log alone" do
      h = handle(last_size: 100)
      # tmux declined the timestamp (nil); a log that keeps growing still proves life.
      strategy.stalled?(h, now: at(8), log_size: 130, activity_at: nil, timeout: 10)
      expect(strategy.stalled?(h, now: at(9), log_size: 130, activity_at: nil, timeout: 10)).to be false
    end
  end

  describe "#descendants" do
    # The tree walk the reaper kills leaf-first. Pure given children_of, so a
    # synthetic tree pins it without spawning anything.
    let(:tree) { { 10 => [11, 12], 11 => [13], 12 => [], 13 => [] } }
    let(:children_of) { ->(pid) { tree.fetch(pid, []) } }

    it "collects a pid and every descendant" do
      expect(strategy.descendants(10, children_of)).to contain_exactly(10, 11, 12, 13)
    end

    it "lists parents before their children, so reverse kills leaves first" do
      order = strategy.descendants(10, children_of)
      expect(order.index(10)).to be < order.index(11)
      expect(order.index(11)).to be < order.index(13)
    end

    it "does not loop forever on a cycle" do
      cyclic = ->(pid) { { 1 => [2], 2 => [1] }.fetch(pid, []) }
      expect(strategy.descendants(1, cyclic)).to contain_exactly(1, 2)
    end
  end
end
