# frozen_string_literal: true

require "open3"
require "pathname"
require "time"

module HColumns
  module Providers
    # On-demand git history provider. Expanding a file node queries that file's
    # recent commits (bounded) and emits CO_CHANGED_WITH (files that moved with it)
    # and CHANGED_BY (its authors). Two git invocations per file; scoped to the
    # selected file, consistent with the pull model. Bounds are explicit below.
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
        path = Filesystem.path_of(node)
        path ? (File.file?(path) && path.start_with?("#{@root}/")) : false
      end

      def expand(node, graph, now:)
        path = Filesystem.path_of(node)
        return unless path && File.file?(path)

        rel = relative(path)
        commits = commits_touching(rel)
        return if commits.empty?

        co_change, authors = aggregate(commits)
        emit_co_change(node, graph, co_change, total: commits.size, now: now)
        emit_authors(node, graph, authors, total: commits.size, now: now)
      end

      private

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
          graph.observe(Observation.new(
            provider: :git, subject_id: node.id, target_id: target.id,
            edge_type: :CO_CHANGED_WITH, weight: agg[:count].to_f, evidence_kind: :history,
            observed_at: agg[:latest] || now,
            evidence_summary: "changed together in #{agg[:count]} of #{total} commits"
          ))
        end
      end

      def emit_authors(node, graph, authors, total:, now:)
        authors.each do |name, agg|
          target = graph.add_node(author_node(name))
          graph.observe(Observation.new(
            provider: :git, subject_id: node.id, target_id: target.id,
            edge_type: :CHANGED_BY, weight: agg[:count].to_f, evidence_kind: :history,
            observed_at: agg[:latest] || now,
            evidence_summary: "#{agg[:count]} of #{total} commits"
          ))
        end
      end

      def author_node(name)
        Node.new(type: :Person, identity: { scheme: "git.author", key: name }, properties: { name: name })
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
