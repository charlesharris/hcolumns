# frozen_string_literal: true

require "fileutils"
require "json"

module HColumns
  # `hcol init` — wire the agent bridge into ANY repo (hc-ouk).
  #
  # hcolumns' own .claude/ was the only place the hook and the skill existed, so
  # the live-session stratum was a feature of this repo rather than of the gem.
  # This materializes both from `templates/` — the same files hcolumns itself
  # runs in place (no copy here, so a fix made while dogfooding is the fix other
  # repos get; see AGENTS.md) — into a target repo:
  #
  #   .claude/hooks/agent_bridge_hook.rb   the Claude Code -> `hcol bridge` translator
  #   .claude/skills/hcol/SKILL.md         how an agent reads/enriches the graph
  #   .claude/settings.json                the four hook events that drive it
  #
  # Idempotent, and never destructive: settings.json is MERGED (a repo's existing
  # hooks are somebody's working setup, not our canvas), and a hook that differs
  # from the template is backed up before refresh — the header invites swapping
  # the script for a different agent, so a local edit is a feature to preserve,
  # not drift to overwrite.
  class Initializer
    # Raised for the one thing init can't safely proceed through: a target
    # settings.json we can't parse (and therefore can't merge without loss).
    Error = Class.new(StandardError)

    TEMPLATES = File.expand_path("templates", __dir__)

    # The hook events that make a session legible: turns (UserPromptSubmit),
    # test lifecycle (Pre/PostToolUse on Bash), edits, and the turn's close +
    # token usage (Stop). Matchers mirror the dogfood settings.json.
    EVENTS = [
      # Once per session: the pointer to the raw transcript (hc-33x). Fires here
      # rather than on Stop so the log gains one line, not one per turn.
      { event: "SessionStart", matcher: nil },
      { event: "UserPromptSubmit", matcher: nil },
      { event: "PreToolUse", matcher: "Bash" },
      { event: "PostToolUse", matcher: "Edit|Write|MultiEdit|NotebookEdit|Bash" },
      { event: "Stop", matcher: nil }
    ].freeze

    HOOK_MARKER = "agent_bridge_hook.rb"

    Result = Struct.new(:status, :path, :note, keyword_init: true)

    def initialize(root)
      @root = File.expand_path(root)
    end

    attr_reader :root

    # Returns [Result, ...] — what init did, for the CLI to report.
    def run
      [
        copy(File.join(TEMPLATES, "agent_bridge_hook.rb"), hook_path, executable: true),
        copy(File.join(TEMPLATES, "SKILL.md"), File.join(@root, ".claude", "skills", "hcol", "SKILL.md")),
        merge_settings,
        ignore_runtime_artifacts
      ]
    end

    # Everything under .hcolumns/ is a RUNTIME artifact of this machine's runs — the
    # live session log, per-task prompts and pane output, and the audit trail of what
    # was dispatched. None of it is anyone else's business and all of it would be a
    # merge conflict, so init claims the ignore rather than leaving every repo to
    # discover the noise (or, worse, to commit its own audit log).
    #
    # Appends a marked block and never rewrites what is already there: .gitignore is
    # the user's file, and an init that reformats it is an init people stop running.
    IGNORE_MARKER = "# hcolumns runtime artifacts"
    IGNORE_BLOCK = <<~GITIGNORE
      #{IGNORE_MARKER} (hcol init) — local logs, per-task output, dispatch audit trail
      .hcolumns/
    GITIGNORE

    def ignore_runtime_artifacts
      path = File.join(@root, ".gitignore")
      existing = File.file?(path) ? File.read(path) : ""
      return Result.new(status: :unchanged, path: path) if existing.include?(IGNORE_MARKER)

      body = existing.empty? || existing.end_with?("\n") ? existing : "#{existing}\n"
      File.write(path, "#{body}#{existing.empty? ? '' : "\n"}#{IGNORE_BLOCK}")
      Result.new(status: File.size?(path) && !existing.empty? ? :updated : :created, path: path,
                 note: "ignoring .hcolumns/")
    end

    # The hook command written into settings.json. $CLAUDE_PROJECT_DIR keeps it
    # correct no matter which subdirectory a session runs from; `hcol` (not a
    # path) resolves the installed gem, which is what every repo but this one has.
    def hook_command
      %(ruby "$CLAUDE_PROJECT_DIR/.claude/hooks/#{HOOK_MARKER}")
    end

    private

    def hook_path
      File.join(@root, ".claude", "hooks", "agent_bridge_hook.rb")
    end

    def settings_path
      File.join(@root, ".claude", "settings.json")
    end

    def copy(from, to, executable: false)
      body = File.read(from)
      if File.file?(to)
        return Result.new(status: :unchanged, path: to) if File.read(to) == body

        backup = "#{to}.bak"
        FileUtils.cp(to, backup)
        write(to, body, executable: executable)
        return Result.new(status: :updated, path: to, note: "previous version saved to #{rel(backup)}")
      end

      write(to, body, executable: executable)
      Result.new(status: :written, path: to)
    end

    def write(to, body, executable: false)
      FileUtils.mkdir_p(File.dirname(to))
      File.write(to, body)
      FileUtils.chmod(0o755, to) if executable
    end

    # Add our four hook entries to whatever is already there. Idempotent by the
    # hook's FILENAME rather than the exact command string: a repo that wrapped
    # the command (an env var, a different ruby) is still wired, and re-running
    # init must not staple a second copy beside their version.
    def merge_settings
      settings = read_settings
      hooks = (settings["hooks"] ||= {})
      added = EVENTS.reject { |e| wired?(hooks[e[:event]]) }

      return Result.new(status: :unchanged, path: settings_path, note: "already wired") if added.empty?

      added.each do |spec|
        entry = { "hooks" => [{ "type" => "command", "command" => hook_command }] }
        entry = { "matcher" => spec[:matcher] }.merge(entry) if spec[:matcher]
        (hooks[spec[:event]] ||= []) << entry
      end

      existed = File.file?(settings_path)
      write(settings_path, "#{JSON.pretty_generate(settings)}\n")
      Result.new(status: existed ? :merged : :written, path: settings_path,
                 note: "+ #{added.map { |e| e[:event] }.join(', ')}")
    end

    def wired?(entries)
      Array(entries).any? do |entry|
        Array(entry["hooks"]).any? { |h| h["command"].to_s.include?(HOOK_MARKER) }
      end
    end

    # A repo's settings.json is hand-edited and may be broken; refuse to merge
    # into what we can't parse rather than silently replacing their file.
    def read_settings
      return {} unless File.file?(settings_path)

      JSON.parse(File.read(settings_path))
    rescue JSON::ParserError => e
      raise Error, "#{rel(settings_path)} is not valid JSON (#{e.message.lines.first.to_s.strip}) — " \
                   "fix or move it, then re-run `hcol init`"
    end

    def rel(path)
      path.start_with?("#{@root}/") ? path.sub("#{@root}/", "") : path
    end
  end
end
