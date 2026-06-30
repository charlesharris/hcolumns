# frozen_string_literal: true

# Content facets: a node's *contents* as a tab (file text, a commit's diff, a
# run's output) — distinct from its relation column, and a derived view (never
# folded into the graph). Each only offers its tab when there's real content.
RSpec.describe "content modes" do
  def now = FIXED_NOW

  let(:resolver) { HColumns::ModeResolver.new }

  # a node pointing at a real file on disk (this very spec file)
  def fs_node(path)
    HColumns::Providers::Filesystem.node_for(path)
  end

  describe HColumns::SourceMode do
    let(:mode) { HColumns::Mode[:source] }

    it "offers its tab only for a real, readable file" do
      expect(mode.applies?(fs_node(__FILE__))).to be true
      # a demo fixture SourceFile whose path doesn't exist on disk -> no tab
      fixture = HColumns::Providers::InMemoryFixture.build(now: now)
      orders = fixture.node(HColumns::Providers::InMemoryFixture.orders_id)
      expect(mode.applies?(orders)).to be false
    end

    it "renders the file's text as a numbered, bounded listing" do
      panel = mode.panel(fs_node(__FILE__), nil, now: now)
      section = panel.sections.first

      expect(section.heading).to eq("CONTENTS")
      expect(section.lines.first).to include("content_modes_spec.rb") # the name header
      body = section.lines.join("\n")
      expect(body).to include("frozen_string_literal")               # actual file content
      expect(body).to match(/^\s+1  /)                               # line numbers
    end

    it "guards against a huge blob" do
      allow(File).to receive(:size).and_return(2_000_000)
      lines, = HColumns::Providers::Filesystem.read_lines(__FILE__)
      expect(lines).to eq(["(file too large to preview)"])
    end
  end

  describe HColumns::GitDiffMode do
    let(:mode) { HColumns::Mode[:gitdiff] }
    let(:repo) { HColumns::Providers::Git.repo_root(Dir.pwd) }
    let(:head_sha) { `git -C #{repo} rev-parse HEAD`.strip }
    let(:commit) do
      HColumns::Node.new(type: :Commit, identity: { scheme: "git.commit", key: head_sha },
                         properties: { name: "HEAD", sha: head_sha, repo: repo })
    end

    it "offers its tab for a commit carrying a sha + repo" do
      expect(mode.applies?(commit)).to be true
      expect(mode.applies?(fs_node(__FILE__))).to be false # a file is not a commit
    end

    it "renders the commit's diff" do
      panel = mode.panel(commit, nil, now: now)
      expect(panel.sections.first.heading).to start_with("DIFF #{head_sha[0, 7]}")
      body = panel.sections.first.lines.join("\n")
      expect(body).to match(/^(commit|diff --git|Author:)/) # a real git-show payload
    end
  end

  describe HColumns::OutputMode do
    let(:mode) { HColumns::Mode[:output] }

    it "renders a node's captured output, with the right heading" do
      run = HColumns::Node.new(type: :TestRun, identity: { scheme: "agent.test", key: "x" },
                               properties: { name: "rspec — 84 examples", output: %w[line-a line-b] })
      panel = mode.panel(run, nil, now: now)
      expect(panel.sections.first.heading).to eq("TEST OUTPUT")
      expect(panel.sections.first.lines).to eq(%w[line-a line-b])
    end

    it "falls back to the node's summary line when no output was captured" do
      log = HColumns::Node.new(type: :LogLine, identity: { scheme: "agent.log", key: "y" },
                               properties: { name: "0 failures (0.9s)" })
      panel = mode.panel(log, nil, now: now)
      expect(panel.sections.first.heading).to eq("LOG")
      expect(panel.sections.first.lines).to eq(["0 failures (0.9s)"])
    end
  end

  describe HColumns::ModeResolver do
    it "makes the content facet the auto mode for the types it fits" do
      commit = HColumns::Node.new(type: :Commit, identity: { scheme: "git.commit", key: "z" },
                                  properties: { sha: "z", repo: "/tmp" })
      test = HColumns::Node.new(type: :TestRun, identity: { scheme: "agent.test", key: "t" })
      expect(resolver.auto(commit).name).to eq(:gitdiff)
      expect(resolver.auto(test).name).to eq(:output)
    end

    it "adds a source tab to a real file's column without displacing its auto mode" do
      source_file = File.expand_path("../lib/hcolumns.rb", __dir__) # a real SourceFile (not a _spec)
      modes = resolver.modes_for(fs_node(source_file)).map(&:name)
      expect(modes.first).to eq(:default) # relations still open by default
      expect(modes).to include(:source)   # ...with contents one tab away
    end
  end

  describe "the agent session's run + log carry real output" do
    let(:graph) { HColumns::Providers::AgentSession.build(now: now) }

    it "fills the TestRun's output facet from the fixture" do
      run = graph.nodes.find { |n| n.type == :TestRun }
      panel = HColumns::Mode[:output].panel(run, nil, now: now)
      expect(panel.sections.first.lines.join("\n")).to include("84 examples, 0 failures")
    end
  end
end
