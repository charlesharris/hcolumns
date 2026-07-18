# frozen_string_literal: true

require "tmpdir"
require "open3"

# The isolation half of UI dispatch (hc-4s4, layer 34b). These run against a REAL
# git repo in a tmpdir rather than a stubbed shell: the whole value of a worktree is
# what git actually does with it, and a doubled `git` would pin our beliefs about
# git instead of git's behaviour — which is precisely the class of bug (a worktree
# that silently isn't one) this class exists to prevent.
RSpec.describe HColumns::Worktrees do
  around do |ex|
    Dir.mktmpdir("hcol-worktrees") do |dir|
      @repo = dir
      git("init", "-q", "-b", "main")
      git("config", "user.email", "test@example.com")
      git("config", "user.name", "Test")
      File.write(File.join(dir, "README.md"), "hello\n")
      git("add", "-A")
      git("commit", "-qm", "initial")
      ex.run
    end
  end

  def git(*args, dir: @repo)
    out, err, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end

  subject(:worktrees) { described_class.new(repo: @repo) }

  describe "#ensure" do
    it "creates a checkout on its own hcol/<key> branch" do
      path = worktrees.ensure("abc123")

      expect(File.directory?(path)).to be true
      expect(File.file?(File.join(path, "README.md"))).to be true
      expect(git("rev-parse", "--abbrev-ref", "HEAD", dir: path).strip).to eq("hcol/abc123")
    end

    it "is idempotent — a second call returns the same tree, not a second one" do
      first = worktrees.ensure("abc123")
      second = worktrees.ensure("abc123")

      expect(second).to eq(first)
      trees = git("worktree", "list", "--porcelain").lines.count { |l| l.start_with?("worktree ") }
      expect(trees).to eq(2) # the main checkout plus exactly one added
    end

    it "re-checks out an existing branch rather than failing on 'already exists'" do
      worktrees.ensure("abc123")
      worktrees.remove("abc123") # tree gone, branch kept — the state cleanup leaves behind

      path = worktrees.ensure("abc123")
      expect(git("rev-parse", "--abbrev-ref", "HEAD", dir: path).strip).to eq("hcol/abc123")
    end

    it "lives under .git, so the working tree it protects stays clean" do
      worktrees.ensure("abc123")

      expect(git("status", "--porcelain").strip).to eq("")
    end
  end

  # The promise the whole design rests on: a browser click cannot dirty the checkout
  # the human is sitting in. If this ever fails, --dispatch is unsafe to ship.
  it "keeps a commit made in the worktree off the main checkout" do
    path = worktrees.ensure("abc123")
    File.write(File.join(path, "NEW.md"), "agent wrote this\n")
    git("add", "-A", dir: path)
    git("commit", "-qm", "agent commit", dir: path)

    expect(File.exist?(File.join(@repo, "NEW.md"))).to be false
    expect(git("rev-parse", "HEAD").strip).to eq(git("rev-parse", "main").strip)
    expect(git("status", "--porcelain").strip).to eq("")
  end

  describe "auditable facts about what the agent did" do
    before do
      path = worktrees.ensure("abc123")
      File.write(File.join(path, "NEW.md"), "one\ntwo\n")
      git("add", "-A", dir: path)
      git("commit", "-qm", "agent commit", dir: path)
    end

    it "reports the branch head" do
      expect(worktrees.head("abc123")).to match(/\A[0-9a-f]{40}\z/)
    end

    it "reports commits the branch added, not the base's history" do
      commits = worktrees.commits("abc123")

      expect(commits.map { |c| c[:subject] }).to eq(["agent commit"])
    end

    it "reports a diffstat of what changed" do
      expect(worktrees.diffstat("abc123")).to match(/1 file changed/)
    end

    it "says so plainly when the agent committed nothing" do
      worktrees.ensure("empty1")

      expect(worktrees.diffstat("empty1")).to eq("no changes")
    end
  end

  describe "#remove" do
    it "reclaims the checkout but KEEPS the branch — the commits are the deliverable" do
      path = worktrees.ensure("abc123")
      File.write(File.join(path, "NEW.md"), "work\n")
      git("add", "-A", dir: path)
      git("commit", "-qm", "agent commit", dir: path)

      expect(worktrees.remove("abc123")).to be true
      expect(File.directory?(path)).to be false
      expect(worktrees.branch?("hcol/abc123")).to be true
    end

    it "treats an absent tree as already-removed rather than an error" do
      expect(worktrees.remove("never-made")).to be false
    end
  end

  describe "key derivation" do
    it "derives path and branch from the key alone, so a later runner can adopt" do
      expect(worktrees.branch_for("abc123")).to eq("hcol/abc123")
      expect(worktrees.path_for("abc123")).to eq(File.join(@repo, ".git", "hcolumns", "worktrees", "abc123"))
    end

    it "sanitises a key that would not survive as a branch or directory name" do
      expect(worktrees.branch_for("live:a.b")).to eq("hcol/live-a-b")
    end
  end
end
