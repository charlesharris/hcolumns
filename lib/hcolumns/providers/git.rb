# frozen_string_literal: true

require "open3"
require "pathname"
require "time"

module HColumns
  module Providers
    # On-demand git provider, two-faced:
    #
    #   * a file node  -> CO_CHANGED_WITH (files that moved with it) + CHANGED_BY
    #     (its authors), from that file's recent history.
    #   * the repo root -> the git *structure*: HEAD + HAS_BRANCH; a Branch ->
    #     POINTS_AT its tip; a Commit -> PARENT commits, CHANGED files, AUTHORED_BY.
    #
    # So the repo root is the entrypoint into "git headspace" (the `git` lens lifts
    # these families), navigated with the same columns. Authors reuse the
    # `git.author` identity, so a Person reached via a commit is the same node as
    # one reached via a file's CHANGED_BY. Everything stays scoped to the selected
    # node, consistent with the pull model; bounds are explicit below.
    class Git
      MAX_COMMITS = 100          # how far back per file
      MAX_FILES_PER_COMMIT = 50  # skip bulk/merge commits as co-change noise

      # The git work-tree root for a path, or nil if it isn't in a repo.
      def self.repo_root(path)
        dir = File.directory?(path) ? path : File.dirname(path)
        out, _err, status = Open3.capture3("git", "-C", dir, "rev-parse", "--show-toplevel")
        status.success? ? out.strip : nil
      end

      def initialize(repo_root)
        @root = repo_root
      end

      def recognizes?(node)
        case node.identity[:scheme]
        when "fs.path"
          path = Filesystem.path_of(node)
          return false unless path

          (File.file?(path) && path.start_with?("#{@root}/")) || repo_root_dir?(path)
        when "git.branch", "git.commit"
          node.properties[:repo] == @root
        else
          false
        end
      end

      def expand(node, graph, now:)
        case node.identity[:scheme]
        when "fs.path"
          path = Filesystem.path_of(node)
          return unless path

          if repo_root_dir?(path) then expand_repo(node, graph, now: now)
          elsif File.file?(path) then expand_file(node, graph, now: now)
          end
        when "git.branch" then expand_branch(node, graph, now: now)
        when "git.commit" then expand_commit(node, graph, now: now)
        end
      end

      private

      # --- the repo as graph: repo -> branches/HEAD -> commits -> files/people ---

      def expand_repo(node, graph, now:)
        if (sha = head_sha)
          head = graph.add_node(commit_node(commit_meta(sha)))
          observe(graph, node,head, :HEAD, weight: 1.0, kind: :structure, at: now, summary: "HEAD")
        end
        branches.each do |branch|
          target = graph.add_node(branch_node(branch))
          observe(graph, node,target, :HAS_BRANCH, weight: 1.0, kind: :structure,
                  at: branch[:date] || now, summary: "branch #{branch[:name]}")
        end
      end

      def expand_branch(node, graph, now:)
        tip = node.properties[:tip]
        meta = tip && commit_meta(tip)
        return unless meta

        target = graph.add_node(commit_node(meta))
        observe(graph, node,target, :POINTS_AT, weight: 1.0, kind: :structure,
                at: meta[:date] || now, summary: "tip #{short(tip)}")
      end

      def expand_commit(node, graph, now:)
        sha = node.properties[:sha]
        meta = sha && commit_meta(sha)
        return unless meta

        author = graph.add_node(author_node(meta[:author]))
        observe(graph, node,author, :AUTHORED_BY, weight: 1.0, kind: :history,
                at: meta[:date] || now, summary: "authored by #{meta[:author]}")

        meta[:parents].each do |parent_sha|
          parent = commit_meta(parent_sha) or next
          target = graph.add_node(commit_node(parent))
          observe(graph, node,target, :PARENT, weight: 1.0, kind: :history,
                  at: parent[:date] || now, summary: "parent #{short(parent_sha)}")
        end

        commit_files(sha).each do |rel|
          abs = File.join(@root, rel)
          next unless File.exist?(abs)

          target = graph.add_node(Filesystem.node_for(abs))
          observe(graph, node,target, :CHANGED, weight: 1.0, kind: :history,
                  at: meta[:date] || now, summary: "changed in #{short(sha)}")
        end
      end

      def repo_root_dir?(path)
        File.directory?(path) && same_path?(path, @root)
      end

      def same_path?(one, two)
        File.realpath(one) == File.realpath(two)
      rescue SystemCallError
        File.expand_path(one) == File.expand_path(two)
      end

      # --- a file's history: CO_CHANGED_WITH + CHANGED_BY (the original face) ---

      def expand_file(node, graph, now:)
        path = Filesystem.path_of(node)
        commits = commits_touching(relative(path))
        return if commits.empty?

        co_change, authors = aggregate(commits)
        emit_co_change(node, graph, co_change, total: commits.size, now: now)
        emit_authors(node, graph, authors, total: commits.size, now: now)
      end

      # => { other_rel => {count:, latest:Time}, ... }, { author => {count:, latest:} }
      def aggregate(commits)
        files_by_commit = files_for(commits.map { |c| c[:hash] })
        co_change = Hash.new { |h, k| h[k] = { count: 0, latest: nil } }
        authors = Hash.new { |h, k| h[k] = { count: 0, latest: nil } }

        commits.each do |commit|
          files = files_by_commit[commit[:hash]] || []
          next if files.size > MAX_FILES_PER_COMMIT

          bump(authors[commit[:author]], commit[:date])
          files.each { |f| bump(co_change[f], commit[:date]) unless f == commit[:rel] }
        end
        [co_change, authors]
      end

      def emit_co_change(node, graph, co_change, total:, now:)
        co_change.each do |rel, agg|
          abs = File.join(@root, rel)
          next unless File.exist?(abs) # skip since-deleted/renamed paths

          target = graph.add_node(Filesystem.node_for(abs))
          observe(graph, node, target, :CO_CHANGED_WITH, weight: agg[:count].to_f, kind: :history,
                  at: agg[:latest] || now, summary: "changed together in #{agg[:count]} of #{total} commits")
        end
      end

      def emit_authors(node, graph, authors, total:, now:)
        authors.each do |name, agg|
          target = graph.add_node(author_node(name))
          observe(graph, node, target, :CHANGED_BY, weight: agg[:count].to_f, kind: :history,
                  at: agg[:latest] || now, summary: "#{agg[:count]} of #{total} commits")
        end
      end

      # One place every git edge is appended — all observations carry provider :git.
      def observe(graph, subject, target, type, weight:, kind:, at:, summary:)
        graph.observe(Observation.new(
          provider: :git, subject_id: subject.id, target_id: target.id, edge_type: type,
          weight: weight, evidence_kind: kind, observed_at: at, evidence_summary: summary
        ))
      end

      def author_node(name)
        Node.new(type: :Person, identity: { scheme: "git.author", key: name }, properties: { name: name })
      end

      # --- git-structure queries + node builders --------------------------------

      def head_sha
        sha = git("rev-parse", "HEAD").strip
        sha.empty? ? nil : sha
      end

      # [{name:, tip:sha, date:Time}] for local branches.
      def branches
        out = git("for-each-ref", "--format=%(refname:short)%1f%(objectname)%1f%(committerdate:iso-strict)",
                  "refs/heads")
        out.each_line.filter_map do |line|
          name, tip, iso = line.chomp.split("\x1f")
          name && { name: name, tip: tip, date: parse_time(iso) }
        end
      end

      # {sha:, author:, date:Time, parents:[sha,...], subject:} or nil if unknown.
      def commit_meta(sha)
        out = git("log", "-1", "--format=%H%x1f%an%x1f%aI%x1f%P%x1f%s", sha)
        return nil if out.strip.empty?

        hash, author, iso, parents, subject = out.chomp.split("\x1f")
        { sha: hash, author: author, date: parse_time(iso),
          parents: (parents || "").split, subject: subject.to_s }
      end

      # Files touched by a commit; [] for a bulk/merge commit (co-change noise).
      def commit_files(sha)
        files = git("show", "--no-renames", "--name-only", "--format=", sha)
               .each_line.map(&:chomp).reject(&:empty?)
        files.size > MAX_FILES_PER_COMMIT ? [] : files
      end

      def commit_node(meta)
        Node.new(
          type: :Commit, identity: { scheme: "git.commit", key: meta[:sha] },
          properties: { name: "#{short(meta[:sha])} #{meta[:subject]}".strip, sha: meta[:sha],
                        subject: meta[:subject], author: meta[:author], repo: @root }
        )
      end

      def branch_node(branch)
        Node.new(
          type: :Branch, identity: { scheme: "git.branch", key: "#{@root}\x1f#{branch[:name]}" },
          properties: { name: branch[:name], tip: branch[:tip], repo: @root }
        )
      end

      def short(sha)
        sha.to_s[0, 7]
      end

      def bump(agg, time)
        agg[:count] += 1
        agg[:latest] = time if agg[:latest].nil? || (time && time > agg[:latest])
      end

      # [{hash:, author:, date:Time, rel:}] for commits touching rel, newest first.
      def commits_touching(rel)
        out = git("log", "--max-count=#{MAX_COMMITS}", "--format=%H%x1f%an%x1f%aI", "--", rel)
        out.each_line.filter_map do |line|
          hash, author, iso = line.chomp.split("\x1f")
          hash && { hash: hash, author: author, date: parse_time(iso), rel: rel }
        end
      end

      # { hash => [files...] } — all files in each commit (the co-changed set).
      def files_for(hashes)
        return {} if hashes.empty?

        out = git("log", "--no-walk=unsorted", "--name-only", "--format=%x1f%H", *hashes)
        out.split("\x1f").each_with_object({}) do |chunk, acc|
          next if chunk.strip.empty?

          lines = chunk.split("\n")
          hash = lines.shift
          acc[hash] = lines.reject { |l| l.strip.empty? }
        end
      end

      def relative(path)
        Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s
      end

      def parse_time(iso)
        Time.parse(iso) if iso
      rescue ArgumentError
        nil
      end

      def git(*args)
        out, _err, status = Open3.capture3("git", "-C", @root, *args)
        status.success? ? out : ""
      end
    end
  end
end
