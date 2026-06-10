# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe HColumns::Providers::Git do
  def now = FIXED_NOW

  # A deterministic repo: a.rb co-changes with b.rb twice, with c.rb once.
  around do |example|
    Dir.mktmpdir("hcol-git") do |dir|
      @repo = dir
      run("init", "-q")
      run("config", "user.name", "Tester")
      run("config", "user.email", "tester@example.com")
      commit(%w[a.rb b.rb], "c1", date: "2026-01-01T00:00:00")
      commit(%w[a.rb b.rb], "c2", date: "2026-01-02T00:00:00")
      commit(%w[a.rb c.rb], "c3", date: "2026-01-03T00:00:00")
      example.run
    end
  end

  def run(*args, env: {})
    system(env, "git", "-C", @repo, *args, out: File::NULL, err: File::NULL) or raise "git #{args.inspect} failed"
  end

  def commit(files, message, date:)
    files.each { |f| File.write(File.join(@repo, f), "#{f}:#{message}\n") }
    run("add", *files)
    env = { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date }
    run("commit", "-q", "-m", message, env: env)
  end

  def workspace
    @workspace ||= HColumns::Workspace.new(providers: [described_class.new(@repo)]).tap do |w|
      @a_id = w.add_node(HColumns::Providers::Filesystem.node_for(File.join(@repo, "a.rb"))).id
    end
  end

  def column
    workspace.column_for(@a_id, now: now)
  end

  it "detects the repo root for a path inside it" do
    expect(described_class.repo_root(File.join(@repo, "a.rb"))).to eq(File.realpath(@repo))
  end

  it "emits CO_CHANGED_WITH, ranking the more frequent co-change first" do
    cc = column.groups.find { |g| g.relation == :CO_CHANGED_WITH }
    expect(cc).not_to be_nil
    expect(cc.entries.map { |e| e.target.name }).to eq(["b.rb", "c.rb"]) # b: 2 commits, c: 1
  end

  it "summarizes co-change counts as evidence" do
    cc = column.groups.find { |g| g.relation == :CO_CHANGED_WITH }
    b = cc.entries.find { |e| e.target.name == "b.rb" }
    expect(b.rank_reason).to include("changed together in 2 of 3 commits")
  end

  it "emits CHANGED_BY for the author" do
    by = column.groups.find { |g| g.relation == :CHANGED_BY }
    expect(by.entries.map { |e| e.target.name }).to eq(["Tester"])
  end

  it "does nothing for a file with no history" do
    File.write(File.join(@repo, "untracked.rb"), "x")
    id = workspace.add_node(HColumns::Providers::Filesystem.node_for(File.join(@repo, "untracked.rb"))).id
    expect(workspace.column_for(id, now: now)).to be_empty
  end
end
