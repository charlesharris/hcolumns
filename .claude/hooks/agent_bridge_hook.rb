#!/usr/bin/env ruby
# frozen_string_literal: true

# Thin Claude Code -> hcolumns bridge (hc-gzj). This is the ONLY Claude-Code-aware
# piece: it reads a hook's JSON on stdin, translates it into hcolumns' neutral
# bridge vocabulary, and shells out to `hcol bridge`. hcolumns itself stays
# agent-agnostic — swap this file to bridge a different agent (a git hook, an
# editor, a CI job) without touching the library.
#
# Wire it up in .claude/settings.json (see the sibling settings.json in this dir):
# PostToolUse (Edit|Write|MultiEdit|Bash) and Stop both run this script. Then, in
# the repo, watch a session grow live:
#
#     hcol serve $HCOL_BRIDGE_LOG --live     # browser
#     hcol walk  $HCOL_BRIDGE_LOG --live     # terminal
#
# The log path comes from $HCOL_BRIDGE_LOG (default .hcolumns/live.jsonl).

require "json"

LOG = ENV.fetch("HCOL_BRIDGE_LOG", File.join(Dir.pwd, ".hcolumns", "live.jsonl"))
HCOL = ENV.fetch("HCOL_BIN", "hcol")

# Feed one neutral-vocabulary command to `hcol bridge`. Best-effort: a bridge
# hiccup must never fail the tool call it's observing, so errors are swallowed.
def bridge(command)
  system(HCOL, "bridge", "--log", LOG, *command.split(" "), out: File::NULL, err: File::NULL)
rescue StandardError
  nil
end

# Heuristic pass/fail from a PostToolUse Bash response — an explicit non-zero exit,
# or an rspec-style "N failures" summary in the captured output.
def failed?(response)
  code = response["exit_code"] || response["exitCode"]
  return true if code && code.to_i != 0

  text = [response["stdout"], response["stderr"], response["output"]].compact.join("\n")
  text.match?(/[1-9]\d*\s+failures?\b/) || text.include?("FAILED")
end

# Test-ish shell commands become TestRun lifecycle events; everything else is
# noise for a plan view.
TEST_CMD = /\b(rspec|rake test|bundle exec rspec|npm test|pytest|go test)\b/

# A transcript entry that reads as a human prompt — the same filter the turn
# marker uses above (markup-led prompts are system noise, not asks), so the
# usage slice boundaries match the turn boundaries.
def human_prompt?(entry)
  return false unless entry["type"] == "user"
  return false if entry["isMeta"] || entry["isSidechain"]

  content = entry.dig("message", "content")
  text = content.is_a?(String) ? content : Array(content).filter_map { |b| b["text"] if b.is_a?(Hash) && b["type"] == "text" }.join
  !text.strip.empty? && !text.lstrip.start_with?("<", "[")
end

# Report the current turn's token TOTALS: sum assistant usage since the last
# human prompt in the transcript. Totals + a last-word-wins fold means this
# stateless hook can re-report at any frequency without double-counting —
# today it fires once per turn (Stop); moving it to PostToolUse for live
# ticking is a frequency change, not a design change.
def report_usage(path)
  return unless path && File.readable?(path)

  slice = []
  File.foreach(path) do |line|
    entry = JSON.parse(line) rescue next
    if human_prompt?(entry)
      slice = [] # a new turn's slice begins
    elsif entry["type"] == "assistant" && !entry["isSidechain"] && (usage = entry.dig("message", "usage"))
      slice << usage
    end
  end
  return if slice.empty?

  totals = Hash.new(0)
  slice.each do |usage|
    totals[:in] += usage["input_tokens"].to_i
    totals[:out] += usage["output_tokens"].to_i
    totals[:cache_read] += usage["cache_read_input_tokens"].to_i
    totals[:cache_create] += usage["cache_creation_input_tokens"].to_i
  end
  bridge("usage #{totals.map { |key, count| "#{key}=#{count}" }.join(' ')}")
end

payload = JSON.parse($stdin.read) rescue {}
event = payload["hook_event_name"]
tool = payload["tool_name"]
input = payload["tool_input"] || {}
response = payload["tool_response"] || {}

case event
when "UserPromptSubmit"
  # Each prompt opens a turn — the log partitions into "what each ask produced".
  # Ordinals are assigned at fold time, so this stateless hook just marks.
  # Only HUMAN prompts count: system notifications, task events, and slash-command
  # wrappers arrive through the same hook but start with markup ("<", "[") —
  # logging those as turns is noise (found live, first dogfood session).
  label = payload["prompt"].to_s.strip.gsub(/\s+/, " ")[0, 60]
  bridge("turn #{label}") unless label.empty? || label.start_with?("<", "[")
when "PreToolUse"
  # A test run entering flight: the TestRun node appears in :running (◐) and the
  # matching PostToolUse re-emits it as ✓/✗ — same digest-keyed node, live flip.
  if tool == "Bash" && input["command"].to_s.match?(TEST_CMD)
    bridge("phase testing")
    bridge("test start #{input['command']}")
  end
when "PostToolUse"
  case tool
  when "Edit", "Write", "MultiEdit", "NotebookEdit"
    # The session starts in :editing (the bridge header), so an edit needn't
    # re-assert the phase — only real transitions (below) re-emit the Session node.
    path = input["file_path"] || input["notebook_path"]
    bridge("edit #{path}") if path
  when "Bash"
    cmd = input["command"].to_s
    if cmd.match?(TEST_CMD)
      status = failed?(response) ? "fail" : "ok"
      bridge("test #{status} #{cmd}") # re-emits the node PreToolUse started (◐ → ✓/✗)
    end
  end
when "Stop", "SubagentStop"
  # No `done` here: this log ACCRETES across sessions (the next session appends to
  # the same file), and an eof mid-log stops every TailReader that reaches it —
  # the browser would flip "complete" and go deaf to later events (found live,
  # first dogfood session). `done`/eof belongs to one-shot streams (hcol produce);
  # a standing dogfood log just marks the phase and stays open.
  bridge("phase reviewing")
  # Turn totals land as the turn closes. SubagentStop is skipped: a subagent's
  # transcript would double-count into the same turn.
  report_usage(payload["transcript_path"]) if event == "Stop"
end
