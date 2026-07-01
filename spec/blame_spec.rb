# frozen_string_literal: true

require "tmpdir"

# Per-line blame (vim-fugitive style): a file's lines each tagged with the commit
# that last touched them, descend a line -> that commit's change to *this file*
# (a file-scoped diff), then zoom out to the full commit.
RSpec.describe "per-line blame flow" do
  def now = FIXED_NOW

  # f.rb: line 1 survives from the first commit; lines 2-3 come from the second.
  around do |example|
    Dir.mktmpdir("hcol-blame") do |dir|
      @repo = dir
      git("init", "-q")
      git("config", "user.name", "Ada")
      git("config", "user.email", "ada@example.com")
      File.write(path("f.rb"), "one\ntwo\n")
      commit("first", date: "2026-01-01T00:00:00")
      File.write(path("f.rb"), "one\nTWO changed\nthree\n")
      commit("second", date: "2026-02-02T00:00:00")
      example.run
    end
  end

  def path(rel) = File.join(@repo, rel)

  def git(*args, env: {})
    system(env, "git", "-C", @repo, *args, out: File::NULL, err: File::NULL) or raise "git #{args.inspect} failed"
  end

  def commit(message, date:)
    git("add", "-A")
    git("commit", "-q", "-m", message, env: { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date })
  end

  let(:workspace) do
    HColumns::Workspace.new(providers: [HColumns::Providers::Filesystem.new,
                                        HColumns::Providers::Git.new(@repo)])
  end
  let(:file_node) { workspace.add_node(HColumns::Providers::Filesystem.node_for(path("f.rb"))) }

  describe HColumns::Providers::Git do
    it "blames each line to the commit that last touched it" do
      rows = described_class.blame(@repo, path("f.rb"))
      expect(rows.map { |r| r[:text] }).to eq(["one", "TWO changed", "three"])
      expect(rows[0][:summary]).to eq("first")   # unchanged line -> original commit
      expect(rows[1][:summary]).to eq("second")  # edited line -> latest commit
      expect(rows.map { |r| r[:sha] }.uniq.size).to eq(2)
    end

    it "parses porcelain output without touching git (commit meta reused per sha)" do
      porc = +""
      porc << "1111111111111111111111111111111111111111 1 1 1\n"
      porc << "author Ada\nsummary did a thing\nauthor-time 1700000000\n"
      porc << "\tcode line one\n"
      porc << "1111111111111111111111111111111111111111 2 2\n" # same sha, no repeated meta
      porc << "\tcode line two\n"
      rows = described_class.parse_blame(porc, limit: 10)

      expect(rows.size).to eq(2)
      expect(rows[0]).to include(text: "code line one", author: "Ada", summary: "did a thing", lineno: 1)
      expect(rows[1]).to include(text: "code line two", author: "Ada", lineno: 2)
    end

    it "detects a work-tree without a subprocess and flags uncommitted shas" do
      expect(described_class.in_repo?(path("f.rb"))).to be true
      expect(described_class.in_repo?("/")).to be false
      expect(described_class.committed?("0" * 40)).to be false
      expect(described_class.committed?("abcdef0")).to be true
    end
  end

  describe HColumns::BlameMode do
    let(:mode) { HColumns::Mode[:blame] }

    it "offers the tab for a file in a repo, one focusable item per line -> a CommitFile" do
      expect(mode.applies?(file_node)).to be true
      panel = mode.panel(file_node, workspace, now: now)

      expect(panel.items.size).to eq(3)
      line2 = panel.items[1]
      cf = workspace.node(line2.target_id)
      expect(cf.type).to eq(:CommitFile)
      expect(cf.properties[:path]).to eq(path("f.rb"))
      expect(line2.glyph).to eq(cf.properties[:sha][0, 7]) # the short sha column
      expect(line2.reason).to include("Ada").and include("second")
    end

    it "is offered by the resolver as a tab on a real file" do
      modes = HColumns::ModeResolver.new.modes_for(file_node).map(&:name)
      expect(modes).to include(:blame)
    end
  end

  describe "blame -> file-scoped diff -> zoom out to the full commit" do
    let(:diff) { HColumns::Mode[:gitdiff] }

    it "scopes the landing diff to the file and offers a full-commit zoom-out" do
      blame = HColumns::Mode[:blame].panel(file_node, workspace, now: now)
      cf = workspace.node(blame.items[1].target_id) # line 2, the second commit

      scoped = diff.panel(cf, workspace, now: now)
      expect(scoped.sections.map(&:heading).compact).to include(a_string_starting_with("DIFF f.rb").or(a_string_including("f.rb")), "ZOOM OUT")
      expect(scoped.sections.last.lines.join("\n")).to include("f.rb") # the diff really is this file

      commit = workspace.node(scoped.items.first.target_id) # the ▲ full-commit item
      expect(commit.type).to eq(:Commit)

      full = diff.panel(commit, workspace, now: now)
      expect(full.sections.map(&:heading).compact.first).to eq("DIFF #{commit.properties[:sha][0, 7]}")
      expect(full.sections.any? { |s| s.heading == "ZOOM OUT" }).to be(false) # unscoped: no zoom row
    end
  end
end
