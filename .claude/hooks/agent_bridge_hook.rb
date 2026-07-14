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

payload = JSON.parse($stdin.read) rescue {}
event = payload["hook_event_name"]
tool = payload["tool_name"]
input = payload["tool_input"] || {}
response = payload["tool_response"] || {}

case event
when "PostToolUse"
  case tool
  when "Edit", "Write", "MultiEdit", "NotebookEdit"
    # The session starts in :editing (the bridge header), so an edit needn't
    # re-assert the phase — only real transitions (below) re-emit the Session node.
    path = input["file_path"] || input["notebook_path"]
    bridge("edit #{path}") if path
  when "Bash"
    cmd = input["command"].to_s
    # Only test-ish commands become TestRuns; the rest are noise for a plan view.
    if cmd.match?(/\b(rspec|rake test|bundle exec rspec|npm test|pytest|go test)\b/)
      status = failed?(response) ? "fail" : "ok"
      bridge("phase testing")
      bridge("test #{status} #{cmd}")
    end
  end
when "Stop", "SubagentStop"
  bridge("phase reviewing")
  bridge("done")
end
