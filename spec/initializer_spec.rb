# frozen_string_literal: true

require "tmpdir"
require "json"

# `hcol init` (hc-ouk): the bridge stops being a feature of the hcolumns repo and
# becomes one of the gem. These specs drive the two properties that make it safe
# to run in someone else's repo — it is idempotent, and it never destroys what it
# finds (existing hooks are merged around; a customized hook is backed up).
RSpec.describe HColumns::Initializer do
  around do |example|
    Dir.mktmpdir("hcol-init") do |dir|
      @dir = dir
      example.run
    end
  end

  def init = described_class.new(@dir).run

  def settings = JSON.parse(File.read(File.join(@dir, ".claude", "settings.json")))

  def write_settings(hash)
    FileUtils.mkdir_p(File.join(@dir, ".claude"))
    File.write(File.join(@dir, ".claude", "settings.json"), JSON.generate(hash))
  end

  def statuses(results) = results.to_h { |r| [File.basename(r.path), r.status] }

  it "materializes the hook, the skill and the settings wiring" do
    results = init

    expect(statuses(results)).to eq("agent_bridge_hook.rb" => :written, "SKILL.md" => :written,
                                    "settings.json" => :written, ".gitignore" => :created)
    expect(File.executable?(File.join(@dir, ".claude", "hooks", "agent_bridge_hook.rb"))).to be true
    expect(File.read(File.join(@dir, ".claude", "skills", "hcol", "SKILL.md"))).to include("hcol json session")
    expect(settings["hooks"].keys).to contain_exactly("SessionStart", "UserPromptSubmit", "PreToolUse",
                                                      "PostToolUse", "Stop")
  end

  # Runtime artifacts are local history of local runs. Left untracked they are noise
  # in every `git status`; committed by accident they leak this machine's audit trail
  # of what was dispatched. init claims the ignore so no repo has to discover either.
  describe "the .hcolumns ignore" do
    def gitignore = File.read(File.join(@dir, ".gitignore"))

    it "claims the ignore on a repo that has no .gitignore yet" do
      init
      expect(gitignore).to include(".hcolumns/")
    end

    it "APPENDS to an existing .gitignore rather than rewriting the user's file" do
      File.write(File.join(@dir, ".gitignore"), "*.gem\n/coverage/\n")
      init

      expect(gitignore).to start_with("*.gem\n/coverage/\n")
      expect(gitignore).to include(".hcolumns/")
    end

    it "is idempotent — a second init does not stack duplicate blocks" do
      init
      init

      expect(gitignore.scan(described_class::IGNORE_MARKER).size).to eq(1)
    end

    it "leaves a file that already ignores it untouched" do
      File.write(File.join(@dir, ".gitignore"), "#{described_class::IGNORE_MARKER}\n.hcolumns/\n")
      before = gitignore

      expect(init.map(&:status)).to include(:unchanged)
      expect(gitignore).to eq(before)
    end
  end

  # The templates ARE what hcolumns runs in place (no copy in .claude/), so init
  # can only ship what dogfooding already exercises. Guards the gemspec glob too:
  # SKILL.md is not a .rb and would fall out of a lib/**/*.rb-only package.
  it "copies the same templates hcolumns itself runs" do
    init

    %w[agent_bridge_hook.rb SKILL.md].each do |name|
      shipped = File.join(described_class::TEMPLATES, name)
      expect(File.file?(shipped)).to be true
      installed = Dir.glob(File.join(@dir, ".claude", "**", name)).first
      expect(File.read(installed)).to eq(File.read(shipped))
    end
  end

  it "is idempotent: a second run changes nothing" do
    init
    before = settings

    expect(statuses(init).values).to all(eq(:unchanged))
    expect(settings).to eq(before)
  end

  # The destructive case: a repo's settings.json is somebody's working setup.
  it "merges into existing hooks instead of replacing them" do
    write_settings("permissions" => { "allow" => ["Bash(npm test)"] },
                   "hooks" => { "Stop" => [{ "hooks" => [{ "type" => "command", "command" => "say done" }] }] })

    expect(statuses(init)["settings.json"]).to eq(:merged)
    expect(settings["permissions"]).to eq("allow" => ["Bash(npm test)"])
    commands = settings["hooks"]["Stop"].flat_map { |e| e["hooks"].map { |h| h["command"] } }
    expect(commands.first).to eq("say done")
    expect(commands.last).to include("agent_bridge_hook.rb")
  end

  # Idempotent by FILENAME, not exact string: a repo that wrapped the command
  # (env var, a different ruby) is already wired — don't staple a second copy on.
  it "leaves a wrapped hook command alone" do
    write_settings("hooks" => { "Stop" => [{ "hooks" => [{ "type" => "command",
                                                           "command" => "FOO=1 ruby .claude/hooks/agent_bridge_hook.rb" }] }] })
    init

    expect(settings["hooks"]["Stop"].length).to eq(1)
  end

  # The hook's header invites swapping it for a different agent, so a local edit
  # is a customization to preserve, not drift to silently overwrite.
  it "backs up a modified hook before refreshing it" do
    init
    hook = File.join(@dir, ".claude", "hooks", "agent_bridge_hook.rb")
    File.write(hook, "# mine\n")

    result = init.find { |r| r.path == hook }

    expect(result.status).to eq(:updated)
    expect(File.read("#{hook}.bak")).to eq("# mine\n")
    expect(File.read(hook)).to eq(File.read(File.join(described_class::TEMPLATES, "agent_bridge_hook.rb")))
  end

  it "refuses to merge into settings.json it cannot parse" do
    FileUtils.mkdir_p(File.join(@dir, ".claude"))
    File.write(File.join(@dir, ".claude", "settings.json"), "{ oops")

    expect { init }.to raise_error(described_class::Error, /not valid JSON/)
  end
end
