# frozen_string_literal: true

RSpec.describe HColumns::LogProducer do
  def now = FIXED_NOW

  # A deterministic timeline: the sleeper advances a fake clock instead of really
  # sleeping, so the producer's scheduling is exercised without wall-clock time.
  def fake_time
    t = now
    clock = -> { t }
    sleeper = ->(s) { t += s }
    [clock, sleeper]
  end

  let(:script) { HColumns::Providers::AgentSession.script(now: now) }

  it "writes each scripted event as a line, in order, then an eof marker" do
    io = StringIO.new
    clock, sleeper = fake_time
    described_class.new(script, io: io, clock: clock, sleeper: sleeper).run

    lines = io.string.each_line.map(&:strip).reject(&:empty?)
    expect(lines.size).to eq(script.size + 1)
    expect(HColumns::Persistence.parse_line(lines.last)).to eq(:eof)
  end

  it "sleeps until each event's scheduled offset (never runs ahead of the timeline)" do
    io = StringIO.new
    waits = []
    t = now
    clock = -> { t }
    sleeper = ->(s) { waits << s; t += s }
    described_class.new(script, io: io, clock: clock, sleeper: sleeper).run

    # cumulative sleep reaches the last event's offset; no negative waits emitted.
    expect(waits).to all(be >= 0)
    expect(waits.sum).to be_within(1e-9).of(script.map { |e| e[:after] }.max)
  end

  it "produces a log a TailReader replays into the frozen session graph" do
    io = StringIO.new
    clock, sleeper = fake_time
    described_class.new(script, io: io, clock: clock, sleeper: sleeper).run

    reloaded = HColumns::Persistence.load_string(io.string) # eof skipped
    graph = reloaded.project
    frozen = HColumns::Providers::AgentSession.build(now: now)

    expect(graph.nodes.map(&:id)).to match_array(frozen.nodes.map(&:id))
    expect(graph.edges.map { |e| [e.subject_id, e.target_id, e.type] })
      .to match_array(frozen.edges.map { |e| [e.subject_id, e.target_id, e.type] })
    session = graph.node(HColumns::Providers::AgentSession.session_id)
    expect(session.properties[:phase]).to eq(:reviewing) # last re-emitted phase, still a Symbol
  end
end
