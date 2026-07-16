# frozen_string_literal: true

require "tmpdir"
require "json"

# First-run trust detection (hc-4s4). The dialog is real: verified live in an
# untrusted dir that `claude --dangerously-skip-permissions` does NOT dismiss it
# — hugel3's finding for a different flag holds for this one too.
#
# What makes pressing Enter at it defensible is that we don't GUESS a first run.
# Claude Code records trust in its own config, so "is a dialog coming?" is a fact
# we look up, and the pane check only confirms an expectation. That is the
# opposite of gastown's idle detection, which infers state from pane bytes and
# consequently lies.
RSpec.describe HColumns::Strategies::TmuxClaudeCode do
  around do |example|
    Dir.mktmpdir("hcol-trust") do |dir|
      @dir = dir
      @config = File.join(dir, "claude.json")
      example.run
    end
  end

  def write_config(hash) = File.write(@config, JSON.generate(hash))

  def trusted? = described_class.trusted?("/repo/x", config: @config)

  it "reads trust as a fact from Claude Code's own config" do
    write_config("projects" => { "/repo/x" => { "hasTrustDialogAccepted" => true } })
    expect(trusted?).to be true
  end

  it "knows a first run when the project is tracked but not yet trusted" do
    write_config("projects" => { "/repo/x" => { "hasTrustDialogAccepted" => false } })
    expect(trusted?).to be false
  end

  it "knows a first run when the project is absent entirely" do
    write_config("projects" => {})
    expect(trusted?).to be false
  end

  # A wasted 20s wait beats a wedge with no error: if we can't read the config we
  # assume the dialog may appear and watch for it.
  it "assumes a dialog may appear when the config is unreadable" do
    File.write(@config, "{ not json")
    expect(trusted?).to be false
  end

  # No config at all means a machine where Claude has never run; there is nothing
  # to dismiss into, so don't hold the task up waiting for a dialog.
  it "does not wait on a machine with no Claude config" do
    expect(described_class.trusted?("/repo/x", config: File.join(@dir, "absent.json"))).to be true
  end

# The bug a real run bought: readiness was `❯` alone, but the trust dialog
# draws its selected option as "❯ 1. Yes, I trust this folder". So the instant
# the dialog was accepted it still matched, the prompt was pasted onto a dying
# screen, delivery was marked done, and the task waited out its whole timeout
# for an answer to a question nothing had been asked. Readiness is the prompt
# AND no dialog over it.
it "does not mistake the trust dialog's own ❯ for a ready prompt" do
  dialog = "❯ 1. Yes, I trust this folder\n  2. No, exit"
  expect(dialog).to match(described_class::READY_PROMPT) # the marker alone lies…
  expect(dialog).to match(described_class::TRUST_DIALOG) # …so readiness must exclude this
end

  it "matches the real dialog's wording, not a paraphrase" do
    # Captured verbatim from a live untrusted pane.
    pane = "❯ 1. Yes, I trust this folder\n  2. No, exit\nEnter to confirm · Esc to cancel"
    expect(pane).to match(described_class::TRUST_DIALOG)
  end
end
