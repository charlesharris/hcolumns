# frozen_string_literal: true

require "tmpdir"

# The UI-dispatch hop's queue half (hc-4s4): a click becomes a Request on the bridge
# log — the browser echo of `hcol ask`/`hcol fix`. Queuing only; nothing runs. These
# pin that a dispatch lands a real, replayable Request, and that non-actionable input
# is refused rather than writing a lie into the log.
RSpec.describe HColumns::Dispatcher do
  around { |ex| Dir.mktmpdir("hcol-dispatch") { |d| @log = File.join(d, "live.jsonl"); ex.run } }

  let(:dispatcher) { described_class.new(log: @log, session: "live") }

  def graph = File.open(@log) { |io| HColumns::Persistence.load(io) }.project
  def requests = graph.nodes.select { |n| n.type == :Request }

  def suggestion(fix:)
    HColumns::Node.new(type: :Suggestion, identity: { scheme: "agent.suggest", key: "live:s1" },
                       properties: { name: "collapse repeated read", fix: fix })
  end

  describe "#dispatch_suggestion" do
    it "queues the suggestion's fix as a Request that points back at it" do
      node = suggestion(fix: "collapse the repeated file read into one")
      receipt = dispatcher.dispatch_suggestion(node)

      expect(receipt).to include(ok: true, queued: "fix", id: node.id)
      expect(requests.size).to eq(1)
      expect(requests.first.properties[:prompt]).to eq("collapse the repeated file read into one")
    end

    it "makes the queued request outstanding — a runner can pick it up" do
      dispatcher.dispatch_suggestion(suggestion(fix: "do the thing"))
      expect(HColumns::LLMTaskRunner.outstanding(graph).map { |r| r.properties[:prompt] })
        .to eq(["do the thing"])
    end

    it "refuses a suggestion with no fix — reported for honesty, not action" do
      expect(dispatcher.dispatch_suggestion(suggestion(fix: nil))).to be_nil
      expect(dispatcher.dispatch_suggestion(suggestion(fix: "  "))).to be_nil
    end

    it "refuses a node that isn't a suggestion" do
      other = HColumns::Node.new(type: :SourceFile, identity: { scheme: "fs.path", key: "/x" }, properties: {})
      expect(dispatcher.dispatch_suggestion(other)).to be_nil
      expect(dispatcher.dispatch_suggestion(nil)).to be_nil
    end
  end

  describe "#ask" do
    it "queues an arbitrary prompt as a Request" do
      expect(dispatcher.ask("summarize the tuner")).to include(ok: true, queued: "ask")
      expect(requests.first.properties[:prompt]).to eq("summarize the tuner")
      expect(requests.first.properties[:kind]).to eq(:ask)
    end

    it "collapses whitespace and refuses an empty prompt" do
      expect(dispatcher.ask("  spread   out  ")[:prompt]).to eq("spread out")
      expect(dispatcher.ask("   ")).to be_nil
      expect(dispatcher.ask(nil)).to be_nil
    end
  end
end
