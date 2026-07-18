# frozen_string_literal: true

# The preventive half of the dispatch bargain (hc-4s4, layer 34b), pinned so it
# cannot be lost by accident.
#
# Dispatch runs an agent with --dangerously-skip-permissions, and the mitigations
# are layered: a worktree bounds what git sees, the audit log records what happened,
# and THIS is the bound that keeps the whole thing local. `hcol serve` binds
# 127.0.0.1 and the CLI exposes no way to change it — so the endpoints that can
# start an agent are reachable from this machine only.
#
# A future `--host 0.0.0.0` would silently convert a convenience into remote code
# execution for anyone on the network. That is not a hypothetical worth trusting to
# review, so it is a test: adding the flag is allowed, but only deliberately, with
# this spec in hand and the dispatch question answered.
RSpec.describe "serve is loopback-only" do
  it "binds the loopback interface by default" do
    app = double("App", root_id: "x", dispatch_available?: false, live?: false)

    expect(HColumns::Web::Server.new(app).host).to eq("127.0.0.1")
  end

  it "exposes no --host flag on the CLI" do
    source = File.read(File.expand_path("../../lib/hcolumns/cli.rb", __dir__))

    expect(source).not_to match(/"--host"/),
                          "a --host flag would let `hcol serve --dispatch` accept dispatch from the network; " \
                          "if this is intentional, gate execution to loopback explicitly."
  end
end
