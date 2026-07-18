# frozen_string_literal: true

require "tmpdir"

# The compensating control for the permission trade (hc-4s4, layer 34b). A
# dispatched agent runs unattended with permissions skipped, so the bargain is:
# no approval prompt at the moment of action, but no action without a record.
# These pin the properties that make the record worth having — it appends, it never
# collapses, and a damaged tail does not cost you the history.
RSpec.describe HColumns::Audit do
  around { |ex| Dir.mktmpdir("hcol-audit") { |d| @dir = d; ex.run } }

  let(:clock) { -> { Time.utc(2026, 7, 18, 12, 0, 0) } }
  subject(:audit) { described_class.new(path: File.join(@dir, "audit.jsonl"), clock: clock) }

  it "records an event with a timestamp and arbitrary fields" do
    audit.record("dispatch.spawn", key: "abc", origin: "ui", branch: "hcol/abc")

    expect(audit.entries).to eq([{ at: "2026-07-18T12:00:00Z", event: "dispatch.spawn",
                                   key: "abc", origin: "ui", branch: "hcol/abc" }])
  end

  it "appends — a later record never rewrites an earlier one" do
    audit.record("dispatch.spawn", key: "abc")
    audit.record("dispatch.outcome", key: "abc", status: "done")

    expect(audit.entries.map { |e| e[:event] }).to eq(%w[dispatch.spawn dispatch.outcome])
  end

  # The reason this is not the bridge log. Projection collapses a task's states into
  # one node (that is what makes the UI flip in place); an audit trail must keep
  # every state, including the ones a later event superseded.
  it "keeps superseded states rather than folding them away" do
    audit.record("dispatch.state", key: "abc", status: "pending")
    audit.record("dispatch.state", key: "abc", status: "running")
    audit.record("dispatch.state", key: "abc", status: "failed")

    expect(audit.entries.map { |e| e[:status] }).to eq(%w[pending running failed])
  end

  it "answers 'where did this branch come from' for one task" do
    audit.record("dispatch.spawn", key: "abc", origin: "ui")
    audit.record("dispatch.spawn", key: "zzz", origin: "cli")

    expect(audit.for_task("abc").map { |e| e[:origin] }).to eq(["ui"])
  end

  it "creates the directory rather than dropping the record" do
    nested = described_class.new(path: File.join(@dir, "deep", "audit.jsonl"), clock: clock)

    expect(nested.record("dispatch.spawn", key: "abc")).not_to be_nil
    expect(File.file?(nested.path)).to be true
  end

  it "survives a truncated tail — a crash mid-append must not cost the history" do
    audit.record("dispatch.spawn", key: "abc")
    File.open(audit.path, "a") { |f| f.write('{"at":"2026-07-18T12:00:00Z","eve') }

    expect(audit.entries.map { |e| e[:key] }).to eq(["abc"])
  end

  # Loud, not fatal: a full disk should not kill work already in flight, but a
  # SILENT audit gap is the one failure that would make the whole file worthless.
  it "warns and keeps going when it cannot write" do
    warned = []
    broken = described_class.new(path: File.join(@dir, "audit.jsonl"), clock: clock,
                                 warn: ->(m) { warned << m })
    allow(File).to receive(:open).and_raise(Errno::ENOSPC)

    expect(broken.record("dispatch.spawn", key: "abc")).to be_nil
    expect(warned.first).to include("could not record")
  end

  it "reads an absent trail as empty rather than raising" do
    expect(described_class.new(path: File.join(@dir, "nope.jsonl")).entries).to eq([])
  end
end
