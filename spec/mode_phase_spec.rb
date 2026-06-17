# frozen_string_literal: true

# Slice 2: the agent's phase reorders the modes — the auto tab follows what the
# agent is doing, while manually-pinned tabs stay put.
RSpec.describe "phase-driven modes" do
  def now = FIXED_NOW

  AS = HColumns::Providers::AgentSession

  let(:resolver) { HColumns::ModeResolver.new }
  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:source_file) { graph.node(HColumns::Providers::InMemoryFixture.orders_id) } # a SourceFile

  def session(phase)
    Struct.new(:phase).new(phase)
  end

  describe HColumns::ModeResolver do
    it "floats phase-preferred modes to the head, keeping the by-type tabs as fallback" do
      expect(resolver.auto(source_file).name).to eq(:default) # no phase
      expect(resolver.auto(source_file, session: session(:debugging)).name).to eq(:details)
      expect(resolver.auto(source_file, session: session(:exploring)).name).to eq(:explorer)
    end

    it "won't promote a facet a node can't render" do
      # editing prefers the diff facet, but a SourceFile can't render it -> filtered
      modes = resolver.modes_for(source_file, session: session(:editing)).map(&:name)
      expect(modes).not_to include(:diff)
      expect(modes.first).to eq(:default)
    end

    it "promotes diff for a ProposedChange while editing, reviewer while testing" do
      change = HColumns::Node.new(type: :ProposedChange, identity: { scheme: "agent.change", key: "x" })
      expect(resolver.auto(change, session: session(:editing)).name).to eq(:diff)
      expect(resolver.auto(change, session: session(:testing)).name).to eq(:reviewer)
    end

    it "always keeps details available even when a phase doesn't mention it" do
      expect(resolver.modes_for(source_file, session: session(:exploring)).map(&:name)).to include(:details)
    end
  end

  describe "the live walk following the agent's phase" do
    def live_cascade
      feed = AS.feed(now: now)
      g = HColumns::Graph.new
      feed.release(0.0, into: g) # seed: phase editing
      ws = HColumns::Workspace.new(graph: g)
      ctx = HColumns::SessionContext.new(graph: g, node_id: AS.session_id)
      cascade = HColumns::Cascade.new(ws, AS.session_id, now: now, feed: feed, session: ctx)
      cascade.tick(1.2) # PROPOSES exists
      change = cascade.active_entries.index { |e| e.label.include?("diff:") }
      cascade.move(change)
      cascade.into # descend into the ProposedChange
      cascade
    end

    it "flips a descended frame's auto mode when the agent changes phase" do
      cascade = live_cascade
      expect(cascade.phase).to eq(:editing)
      expect(cascade.active_mode.name).to eq(:diff) # editing -> diff facet

      cascade.tick(4.5) # the agent moves to testing (phase event at t=4.0)
      expect(cascade.phase).to eq(:testing)
      expect(cascade.active_mode.name).to eq(:reviewer) # auto followed the phase
    end

    it "leaves a pinned frame alone across a phase change" do
      cascade = live_cascade
      cascade.next_tab # the user pins a mode
      pinned = cascade.active_mode.name

      cascade.tick(4.5) # phase -> testing
      expect(cascade.phase).to eq(:testing)
      expect(cascade.active_mode.name).to eq(pinned) # the pin survives
    end
  end
end
