# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# The git provider's *structure* face: repo root -> branches/HEAD -> commits ->
# files/people. (Its file-history face lives in git_spec.rb.)
RSpec.describe "HColumns::Providers::Git structure" do
  def now = FIXED_NOW

  # main: c1 (a.rb) <- c2 (a.rb, b.rb); feature also points at c2.
  around do |example|
    Dir.mktmpdir("hcol-gitstruct") do |dir|
      @repo = dir
      run("init", "-q")
      run("config", "user.name", "Tester")
      run("config", "user.email", "tester@example.com")
      commit(%w[a.rb], "c1", date: "2026-01-01T00:00:00")
      run("branch", "-M", "main")
      commit(%w[a.rb b.rb], "c2", date: "2026-01-02T00:00:00")
      run("branch", "feature")
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

  let(:provider) { HColumns::Providers::Git.new(@repo) }
  let(:workspace) { HColumns::Workspace.new(providers: [provider]) }

  def column(node) = workspace.column_for(node.id, now: now)
  def fs(path) = HColumns::Providers::Filesystem.node_for(path)
  def group(col, relation) = col.groups.find { |g| g.relation == relation }

  def repo_column
    workspace.add_node(fs(@repo))
    column(workspace.node(fs(@repo).id))
  end

  it "recognizes the repo root as a git-structure entrypoint" do
    expect(provider.recognizes?(fs(@repo))).to be(true)
  end

  it "expands the repo root into its branches" do
    branches = group(repo_column, :HAS_BRANCH)
    expect(branches.entries.map { |e| e.target.name }).to contain_exactly("main", "feature")
  end

  it "expands the repo root into HEAD (the tip commit)" do
    head = group(repo_column, :HEAD)
    expect(head.entries.size).to eq(1)
    expect(head.entries.first.target.properties[:subject]).to eq("c2")
  end

  it "walks a branch to the commit it POINTS_AT" do
    feature = group(repo_column, :HAS_BRANCH).entries.find { |e| e.target.name == "feature" }.target
    tip = group(column(feature), :POINTS_AT)
    expect(tip.entries.first.target.properties[:subject]).to eq("c2")
  end

  it "expands a commit into its author, changed files, and parent" do
    head_commit = group(repo_column, :HEAD).entries.first.target
    col = column(head_commit)

    expect(group(col, :AUTHORED_BY).entries.map { |e| e.target.name }).to eq(["Tester"])
    expect(group(col, :CHANGED).entries.map { |e| e.target.name }).to contain_exactly("a.rb", "b.rb")
    expect(group(col, :PARENT).entries.first.target.properties[:subject]).to eq("c1")
  end

  it "unifies authorship: a commit's author is the same node as a file's CHANGED_BY" do
    head_commit = group(repo_column, :HEAD).entries.first.target
    from_commit = group(column(head_commit), :AUTHORED_BY).entries.first.target

    a_rb = workspace.add_node(fs(File.join(@repo, "a.rb")))
    from_file = group(column(a_rb), :CHANGED_BY).entries.first.target

    expect(from_commit.id).to eq(from_file.id)
  end
end
