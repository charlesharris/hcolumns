# frozen_string_literal: true

require "tmpdir"

# The CLI's bridge seam. The library below it was well specced and the hook above
# it was hand-verified, but nothing covered the thin layer BETWEEN them — which is
# exactly where a bug lived unnoticed: argv was joined into a single command, so
# the documented "one command per arg" silently folded every later command into
# the first one's argument. It produced a Session literally named
# "Task: … phase exploring" in this repo's own live log for a whole day.
RSpec.describe HColumns::CLI do
  around do |example|
    Dir.mktmpdir("hcol-cli-bridge") do |dir|
      @log = File.join(dir, "live.jsonl")
      example.run
    end
  end

  def run(*argv)
    HColumns::CLI.run(["bridge", "--log", @log, *argv])
  end

  def graph = File.open(@log) { |io| HColumns::Persistence.load(io) }.project

  it "applies one command per arg" do
    run("session work Fix the tuner", "phase testing")

    session = graph.nodes.find { |n| n.type == :Session }
    # The title must stop at the end of ITS OWN arg — not swallow the next command.
    expect(session.properties[:name]).to eq("Task: Fix the tuner")
    expect(session.properties[:phase]).to eq(:testing)
  end

  it "reads one command per line from stdin" do
    allow($stdin).to receive(:each_line).and_yield("session work Fix the tuner\n").and_yield("phase reviewing\n")
    run

    expect(graph.nodes.find { |n| n.type == :Session }.properties[:phase]).to eq(:reviewing)
  end

  # The hook passes exactly one arg per invocation (a fresh process per event).
  it "handles a single command carrying spaces" do
    run("turn make the thing portable")

    expect(graph.turns.first[:label]).to eq("make the thing portable")
  end

  it "reports usage without a log rather than writing somewhere surprising" do
    expect { HColumns::CLI.run(["bridge"]) }.to output(/usage: hcol bridge/).to_stderr
  end
end
