# frozen_string_literal: true

require "open3"
require "fileutils"

module HColumns
  # Git worktrees, keyed by task (hc-4s4, layer 34b). The isolation half of the
  # UI-dispatch bargain: a dispatched agent runs with --dangerously-skip-permissions,
  # so the question is never "can it act?" but "how far does an action reach?" A
  # worktree bounds the GIT blast radius — the agent edits and commits on its own
  # branch, and the working tree you are sitting in is never touched, so a browser
  # click cannot dirty your checkout or move your HEAD.
  #
  # Be honest about what this is NOT: it is not a sandbox. A worktree bounds git,
  # not the process. The agent can still write outside the worktree, reach the
  # network, and read anything you can read. The preventive bounds that DO hold are
  # elsewhere — `hcol serve` binds 127.0.0.1 with no --host flag, and execution is
  # opt-in behind --dispatch. This class is the git-shaped part of a layered answer,
  # and the audit log (see Audit) is what covers the rest, detectively.
  #
  # Everything derives from the task key, exactly like the tmux session name and the
  # task log do. That is what makes a worktree ADOPTABLE: a later runner that never
  # saw the original `start` can still find the tree and the branch from the key
  # alone, which is the same property reconcile/2 already leans on.
  class Worktrees
    class Error < StandardError; end

    # Branch namespace. A slash-prefixed namespace keeps dispatched work visibly
    # separate in `git branch` and makes a bulk cleanup one glob.
    BRANCH_PREFIX = "hcol"

    # Worktrees live UNDER .git, not beside the repo and not inside the working
    # tree. Inside the working tree they would show up as untracked files in the
    # very checkout we are promising not to disturb (and nest a repo inside a repo);
    # beside it they would litter the parent directory, which is not ours. Under
    # .git they are invisible to status, cleaned up with the repo, and sitting in
    # the same place git keeps its own worktree metadata.
    SUBDIR = File.join("hcolumns", "worktrees")

    def initialize(repo:, git: nil, clock: -> { Time.now })
      @repo = File.expand_path(repo)
      @git = git || method(:capture)
      @clock = clock
    end

    attr_reader :repo

    def branch_for(key)
      "#{BRANCH_PREFIX}/#{sanitize(key)}"
    end

    def path_for(key)
      File.join(@repo, ".git", SUBDIR, sanitize(key))
    end

    # The worktree for `key`, created if it does not exist yet. Idempotent by
    # construction — a retry, an adopt, and a second dispatch of the same key all
    # land on the same tree rather than racing to make a second one.
    #
    # Branch handling has two cases on purpose: a fresh key cuts a NEW branch off
    # the current HEAD (`-b`), while a key whose branch already exists (a re-run
    # after the tree was pruned) checks that branch out again instead of failing on
    # "already exists". Both end at the same invariant: path exists, on branch.
    def ensure(key, base: "HEAD")
      path = path_for(key)
      return path if registered?(path)

      FileUtils.mkdir_p(File.dirname(path))
      branch = branch_for(key)
      args = if branch?(branch)
               ["worktree", "add", path, branch]
             else
               ["worktree", "add", "-b", branch, path, base]
             end
      _out, err, ok = @git.call(@repo, *args)
      raise Error, "could not create worktree for #{key}: #{err.to_s.strip}" unless ok

      path
    end

    # Drop the tree but KEEP the branch. The commits are the deliverable — the whole
    # point of review-only merge-back is that a human reads the branch afterwards —
    # so cleanup reclaims the checkout, never the work. Best-effort: a tree that is
    # already gone is a success, not an error.
    def remove(key)
      path = path_for(key)
      return false unless registered?(path)

      _out, _err, ok = @git.call(@repo, "worktree", "remove", "--force", path)
      @git.call(@repo, "worktree", "prune") unless ok
      true
    end

    # What the agent actually committed, asked of git rather than of the agent.
    # This is the load-bearing audit question: an agent's own prose about what it
    # did is a claim, while the sha and the diffstat are the record.
    def head(key)
      out, _err, ok = @git.call(path_for(key), "rev-parse", "HEAD")
      ok ? out.to_s.strip : nil
    end

    # Commits on this branch that are not on `base`, newest first.
    def commits(key, base: "HEAD")
      out, _err, ok = @git.call(@repo, "log", "--format=%H %s", "#{base}..#{branch_for(key)}")
      return [] unless ok

      out.to_s.lines.filter_map do |line|
        sha, subject = line.strip.split(" ", 2)
        { sha: sha, subject: subject.to_s } unless sha.to_s.empty?
      end
    end

    # Files-changed/insertions/deletions against the branch point, so "what did this
    # agent do to my repo" is answerable without reading the diff or trusting the log.
    # Three-dot on purpose: this asks what the BRANCH added since it diverged, not
    # how the branch differs from wherever the main repo's HEAD has wandered to
    # since. Two-dot would grow a phantom diff every time you committed elsewhere.
    def diffstat(key, base: "HEAD")
      out, _err, ok = @git.call(@repo, "diff", "--shortstat", "#{base}...#{branch_for(key)}")
      return nil unless ok

      out.to_s.strip.empty? ? "no changes" : out.to_s.strip
    end

    def branch?(name)
      _out, _err, ok = @git.call(@repo, "rev-parse", "--verify", "--quiet", "refs/heads/#{name}")
      ok
    end

    private

    # A worktree git itself acknowledges, not merely a directory that exists. A
    # leftover directory with no registration would make `worktree add` fail on
    # every subsequent run; asking git keeps `ensure` honest about the difference.
    def registered?(path)
      out, _err, ok = @git.call(@repo, "worktree", "list", "--porcelain")
      return false unless ok

      out.to_s.lines.any? do |line|
        next false unless line.start_with?("worktree ")

        same_path?(line.sub("worktree ", "").strip, path)
      end
    end

    # Compared by REALPATH, not by string. git reports a worktree by its resolved
    # path, and on macOS the system tmpdir is /var → /private/var, so expand_path
    # alone never matched — `ensure` then tried to add a tree that already existed
    # and `remove` reported nothing to remove. Symlinked checkouts are ordinary
    # (tmpdirs, /home → /Users, network mounts), so this is the general fix, not a
    # macOS special case. Falls back to expand_path when a path is already gone,
    # which is exactly the case `remove` asks about.
    def same_path?(a, b)
      File.realpath(a) == File.realpath(b)
    rescue SystemCallError
      File.expand_path(a) == File.expand_path(b)
    end

    # Same character class the tmux session name uses — a key reaches a branch name,
    # a directory name and a session name, and all three have to survive it.
    def sanitize(key)
      key.to_s.gsub(/[^a-zA-Z0-9_-]/, "-")
    end

    def capture(dir, *args)
      out, err, status = Open3.capture3("git", "-C", dir, *args)
      [out, err, status.success?]
    rescue SystemCallError => e
      ["", e.message, false]
    end
  end
end
