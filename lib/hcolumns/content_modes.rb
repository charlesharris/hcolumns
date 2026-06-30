# frozen_string_literal: true

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

  # A commit's diff, via `git show`. Shows for a Commit node that carries the sha
  # and repo the git provider stamps on it.
  class GitDiffMode < Mode
    MAX_LINES = 600

    def initialize(name: :gitdiff)
      super(name: name)
    end

    def applies?(node)
      node.type == :Commit && !node.properties[:sha].nil? && !node.properties[:repo].nil?
    end

    def panel(node, _workspace, now:)
      sha = node.properties[:sha]
      lines = Providers::Git.show(node.properties[:repo], sha, limit: MAX_LINES)
      Panel.new(node: node, mode: name,
                sections: [PanelSection.new(heading: "DIFF #{sha.to_s[0, 7]}", lines: lines)])
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
