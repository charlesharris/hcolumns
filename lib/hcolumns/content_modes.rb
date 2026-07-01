# frozen_string_literal: true

require "pathname"

module HColumns
  # Content facets — a node's *contents* as a tab, distinct from its relations.
  #
  # Where LensMode / DetailFacet / DiffFacet read the graph, these read the world
  # the node points at: the file on disk, the commit in git, the captured output.
  # That content is a **derived view, never folded into the graph** — file bytes
  # and diffs are volatile rendering against the live fs/git, not substrate to
  # event-source. The graph holds the relations; a content mode renders the thing.
  #
  # Each `applies?` guards its tab, so it only shows when there is real content to
  # render (a demo node whose path doesn't exist on disk simply doesn't get the
  # `source` tab). The I/O itself lives in the providers that own it.

  # A file's text, as a numbered, bounded listing.
  class SourceMode < Mode
    MAX_LINES = 400
    FILE_TYPES = %i[SourceFile TestFile Doc File].freeze

    def initialize(name: :source)
      super(name: name)
    end

    def applies?(node)
      FILE_TYPES.include?(node.type) && !readable_path(node).nil?
    end

    def panel(node, _workspace, now:)
      path = readable_path(node)
      lines, truncated, total = Providers::Filesystem.read_lines(path, limit: MAX_LINES)
      header = [node.name.to_s, summary(total, truncated), ""].reject(&:empty?)
      body = lines.each_with_index.map { |line, i| format("%4d  %s", i + 1, line) }
      Panel.new(node: node, mode: name, sections: [PanelSection.new(heading: "CONTENTS", lines: header + body)])
    end

    private

    def summary(total, truncated)
      return "" unless total

      "#{total} line(s)#{truncated ? " · showing first #{MAX_LINES}" : ''}"
    end

    # A real, readable file path, or nil — what gates the tab. Prefers the fs.path
    # identity (absolute), falling back to a bare :path property.
    def readable_path(node)
      path = Providers::Filesystem.path_of(node) || node.properties[:path]
      path if path && File.file?(path)
    end
  end

  # Per-line blame — each line of a file tagged with the commit that last touched
  # it (vim-fugitive style). Every line is a *focusable item* pointing at a
  # CommitFile (that commit's change to *this* file), so descending a line lands on
  # the file-scoped diff, one keypress from the full commit. It materializes the
  # CommitFile nodes it references — a lightweight expansion (the graph gains nodes,
  # not a per-line edge explosion), the one place a facet writes to the graph.
  class BlameMode < Mode
    MAX_LINES = 4000
    FILE_TYPES = %i[SourceFile TestFile Doc File].freeze

    def initialize(name: :blame)
      super(name: name)
    end

    # Cheap gate: a real file inside a git work-tree (no subprocess — the blame
    # itself runs only when the tab is actually opened).
    def applies?(node)
      return false unless FILE_TYPES.include?(node.type)

      path = readable_path(node)
      !path.nil? && Providers::Git.in_repo?(path)
    end

    def panel(node, workspace, now:)
      path = readable_path(node)
      repo = path && Providers::Git.repo_root(path)
      rows = repo ? Providers::Git.blame(repo, path, limit: MAX_LINES) : []
      rel = repo ? relative(repo, path) : node.name.to_s
      items = rows.map { |row| blame_item(row, repo, path, rel, workspace) }
      heading = "BLAME #{rel} (#{rows.size} line#{rows.size == 1 ? '' : 's'})"
      Panel.new(node: node, mode: name, sections: [PanelSection.new(heading: heading, items: items)])
    end

    private

    def blame_item(row, repo, path, rel, workspace)
      code = format("%4d  %s", row[:lineno], row[:text].to_s)
      unless Providers::Git.committed?(row[:sha])
        return PanelItem.new(label: code, glyph: "•", reason: "not committed (working tree)")
      end

      cf = workspace.add_node(
        Providers::Git.commit_file_node(repo, row[:sha], path, rel: rel,
                                        subject: row[:summary], author: row[:author])
      )
      PanelItem.new(label: code, target_id: cf.id, glyph: row[:sha][0, 7],
                    reason: "#{row[:author]} · #{date(row[:time])} · #{row[:summary]}")
    end

    def date(time)
      time ? time.strftime("%Y-%m-%d") : "?"
    end

    def relative(repo, path)
      Pathname.new(path).relative_path_from(Pathname.new(repo)).to_s
    rescue StandardError
      path
    end

    def readable_path(node)
      path = Providers::Filesystem.path_of(node) || node.properties[:path]
      path if path && File.file?(path)
    end
  end

  # A commit's diff, via `git show`. Applies to a Commit (the whole diff) and to a
  # CommitFile (scoped to that file, via the node's :path — the blame landing view).
  # On a CommitFile it carries "zoom out" nav items: the full commit and the current
  # file, both materialized so descending lands on a real node.
  class GitDiffMode < Mode
    MAX_LINES = 600
    DIFF_TYPES = %i[Commit CommitFile].freeze

    def initialize(name: :gitdiff)
      super(name: name)
    end

    def applies?(node)
      DIFF_TYPES.include?(node.type) && !node.properties[:sha].nil? && !node.properties[:repo].nil?
    end

    def panel(node, workspace, now:)
      sha = node.properties[:sha]
      path = node.properties[:path] # present only on a CommitFile -> scope the diff
      lines = Providers::Git.show(node.properties[:repo], sha, path: path, limit: MAX_LINES)
      sections = []
      sections << zoom_section(node, workspace) if node.type == :CommitFile
      label = path ? "DIFF #{sha.to_s[0, 7]} — #{node.properties[:rel] || path}" : "DIFF #{sha.to_s[0, 7]}"
      sections << PanelSection.new(heading: label, lines: lines)
      Panel.new(node: node, mode: name, sections: sections)
    end

    private

    # The zoom-out affordances on a file-scoped diff: the full commit (unscoped diff
    # + its history) and the file as it stands now.
    def zoom_section(node, workspace)
      sha = node.properties[:sha]
      commit = workspace.add_node(
        Providers::Git.commit_node(node.properties[:repo], sha,
                                   subject: node.properties[:subject], author: node.properties[:author])
      )
      items = [PanelItem.new(label: "full commit #{sha.to_s[0, 7]} — #{node.properties[:subject]}",
                             target_id: commit.id, glyph: "▲")]
      if node.properties[:path] && File.file?(node.properties[:path])
        file = workspace.add_node(Providers::Filesystem.node_for(node.properties[:path]))
        items << PanelItem.new(label: "#{node.properties[:rel]} (current file)",
                               target_id: file.id, glyph: "▤")
      end
      PanelSection.new(heading: "ZOOM OUT", items: items)
    end
  end

  # Captured output — a TestRun's run or a LogLine's surrounding lines. Reads the
  # node's :output property (the fixture / a future log provider fills it); falls
  # back to the node's own summary line so the tab is never empty.
  class OutputMode < Mode
    OUTPUT_TYPES = %i[LogLine TestRun].freeze

    def initialize(name: :output)
      super(name: name)
    end

    def applies?(node)
      OUTPUT_TYPES.include?(node.type)
    end

    def panel(node, _workspace, now:)
      lines = node.properties[:output] || [node.name.to_s]
      heading = node.type == :TestRun ? "TEST OUTPUT" : "LOG"
      Panel.new(node: node, mode: name, sections: [PanelSection.new(heading: heading, lines: lines)])
    end
  end
end
