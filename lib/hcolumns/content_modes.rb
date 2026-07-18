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

    # Repo-relative path, resolving symlinks on both sides first — repo_root comes
    # from `git rev-parse` (realpath), so a repo under a symlinked prefix (e.g. the
    # macOS /var -> /private/var tmpdir) would otherwise yield a broken `../../` rel
    # that `git show sha:rel` can't resolve.
    def relative(repo, path)
      Pathname.new(File.realpath(path)).relative_path_from(Pathname.new(File.realpath(repo))).to_s
    rescue StandardError
      Pathname.new(path).relative_path_from(Pathname.new(repo)).to_s rescue path
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

  # The file's contents *as of a commit* — SourceMode's sibling for a CommitFile
  # (the blame/diff landing node). Reads `git show sha:rel` (the blob, not the
  # diff), so it renders even a file a later commit deleted. Same numbered listing
  # as SourceMode, sitting beside the file-scoped diff so a CommitFile answers both
  # "what changed here" and "what did the whole file look like".
  class CommitSourceMode < Mode
    MAX_LINES = 400

    def initialize(name: :commitsource)
      super(name: name)
    end

    # Cheap gate (no subprocess): a CommitFile carrying the coordinates git needs.
    def applies?(node)
      node.type == :CommitFile &&
        !node.properties[:sha].nil? && !node.properties[:repo].nil? && !node.properties[:rel].nil?
    end

    def panel(node, _workspace, now:)
      content = Providers::Git.show_at(node.properties[:repo], node.properties[:sha],
                                       node.properties[:rel], limit: MAX_LINES)
      sha = node.properties[:sha].to_s[0, 7]
      header = ["#{node.properties[:rel]} @ #{sha}", summary(content), ""].reject(&:empty?)
      Panel.new(node: node, mode: name,
                sections: [PanelSection.new(heading: "SOURCE @ #{sha}", lines: header + body_lines(content))])
    end

    private

    def summary(content)
      return "(source unavailable at this commit)" unless content

      _lines, truncated, total = content
      "#{total} line(s)#{truncated ? " · showing first #{MAX_LINES}" : ''}"
    end

    def body_lines(content)
      return [] unless content

      lines, = content
      lines.each_with_index.map { |line, i| format("%4d  %s", i + 1, line) }
    end
  end

  # The session's turns — the log partitioned by :turn markers, each turn listing
  # the nodes its observations touched, every one descendable. The juggler
  # takeaway (survey #1): their per-item transactionId + "View Transaction"
  # column, done the log way — a turn is derived provenance over the event
  # stream, not stored structure. Reads the projection's fold-time turn list
  # (Graph#turns), so a live tail grows this facet as markers land.
  class TurnsMode < Mode
    def initialize(name: :turns)
      super(name: name)
    end

    def applies?(node)
      node.type == :Session
    end

    def panel(node, workspace, now:)
      turns = workspace.graph.turns
      return empty_panel(node) if turns.empty?

      # Newest turn first: in a live session the current turn is what you're
      # watching, and it should grow at the top, not below the fold.
      sections = turns.reverse.map { |t| section_for(t, workspace) }
      sections.unshift(totals_section(turns)) if turns.any? { |t| t[:tokens] }
      Panel.new(node: node, mode: name, sections: sections)
    end

    private

    def empty_panel(node)
      lines = ["(no turns recorded — the producer hasn't emitted turn markers)"]
      Panel.new(node: node, mode: name, sections: [PanelSection.new(heading: "TURNS", lines: lines)])
    end

    def section_for(turn, workspace)
      items = turn[:node_ids].uniq.filter_map { |id| workspace.graph.node(id) }.map do |n|
        PanelItem.new(label: n.name.to_s, target_id: n.id, glyph: "·")
      end
      label = turn[:label] ? " — #{turn[:label]}" : ""
      heading = "TURN #{turn[:index]}#{label} " \
                "(#{items.size} node#{items.size == 1 ? '' : 's'}#{tokens_suffix(turn[:tokens])})"
      PanelSection.new(heading: heading, items: items)
    end

    # Session-wide totals, derived by summing turns at render time — the log
    # records per-turn observations; aggregates are the fold's business.
    def totals_section(turns)
      sums = turns.filter_map { |t| t[:tokens] }.each_with_object(Hash.new(0)) do |tokens, acc|
        tokens.each { |key, count| acc[key] += count }
      end
      line = "#{abbrev(context_of(sums))} in → #{abbrev(sums[:out])} out across #{turns.size} turns"
      PanelSection.new(heading: "TOKENS", lines: [line])
    end

    # "in" is the full context the model saw: fresh input + both cache sides.
    # The split stays in the event for a display that wants it finer-grained.
    def context_of(tokens)
      tokens.values_at(:in, :cache_read, :cache_create).compact.sum
    end

    def tokens_suffix(tokens)
      return "" unless tokens

      " · #{abbrev(context_of(tokens))}→#{abbrev(tokens[:out] || 0)}"
    end

    def abbrev(count)
      return count.to_s if count < 1000
      return format("%.1fk", count / 1000.0).sub(".0k", "k") if count < 1_000_000

      format("%.1fM", count / 1_000_000.0).sub(".0M", "M")
    end
  end

  # A bead's long-form body — title/status header, then description, design,
  # acceptance criteria, notes — read live from the beads database (the same
  # connection the provider walks). A derived view like source/gitdiff: the
  # graph holds the bead's relations; this facet renders the issue itself.
  class BeadMode < Mode
    MAX_LINES = 200
    SECTIONS = { description: "DESCRIPTION", design: "DESIGN",
                 acceptance_criteria: "ACCEPTANCE", notes: "NOTES" }.freeze

    def initialize(name: :bead)
      super(name: name)
    end

    def applies?(node)
      node.type == :Bead && !node.properties[:beads_root].nil? && Providers::Beads.available?
    end

    def panel(node, _workspace, now:)
      body = Providers::Beads.body(node.properties[:beads_root], node.properties[:bead_id])
      sections = body ? body_sections(body) : [PanelSection.new(lines: ["(beads database unreachable)"])]
      Panel.new(node: node, mode: name, sections: sections)
    end

    private

    def body_sections(body)
      header = ["#{body[:id]} — #{body[:title]}",
                ["P#{body[:priority]}", body[:issue_type], body[:status], body[:assignee]].compact.join(" · ")]
      sections = [PanelSection.new(lines: header)]
      SECTIONS.each do |key, heading|
        text = body[key].to_s
        next if text.strip.empty?

        sections << PanelSection.new(heading: heading, lines: clamp(text.split("\n")))
      end
      sections
    end

    def clamp(lines)
      return lines if lines.size <= MAX_LINES

      lines.first(MAX_LINES) + ["… (#{lines.size - MAX_LINES} more lines truncated)"]
    end
  end

  # Captured output — a TestRun's run or a LogLine's surrounding lines. Reads the
  # node's :output property (the fixture / a future log provider fills it); falls
  # back to the node's own summary line so the tab is never empty.
  # The failing assertion, foregrounded (hc-4s4, the debugging phase). `output`
  # shows a run; this shows the REASON it failed. Arriving at a red test and being
  # handed 200 lines of run chrome buries the one thing you came for — the same
  # complaint that made a Transcript open on top consumers instead of 792 blocks.
  #
  # Deliberately NOT a per-framework matrix. Cleaning pane output taught this exact
  # lesson (the gastown trap): a vendor/version table is a maintenance treadmill
  # that still misses the next tool. So the heuristic is SHAPE, not vendor — a
  # marker word, the window of detail under it, an expected/actual pair, and the
  # first thing that looks like a file:line. rspec, minitest, pytest and jest all
  # emit that shape; something that doesn't degrades to "here's the tail", never to
  # a lie.
  #
  # Applicability is what makes this safe to rank FIRST for a TestRun: a passing run
  # has no failure to show, `applies?` says so, and the column falls through to
  # `output` with no policy branch anywhere.
  class FailureMode < Mode
    FAILURE_TYPES = %i[TestRun LogLine].freeze

    # Widely-shared marker words, not a vendor list. Anchored near line start so a
    # passing run that merely mentions "error" in a test NAME doesn't trip it.
    #
    # The optional gutter is what makes this general rather than rspec-shaped:
    # pytest prefixes its assertion lines with `E `, diff-style runners use `>` or
    # `|`, and rspec numbers its failures `1)`. One small allowance covers all of
    # them without naming any.
    MARKER = /^\s*(?:[E>|]\s+|\d+\)\s*)?(?:Failure|Failures|Error|FAILED|FAIL|AssertionError|
                 Assertion|Traceback|panic|✗|●)\b/xi

    # The expected/actual pair, which is the sentence a human actually reads.
    EXPECTATION = /^\s*(?:expected|actual|got|to\s+equal|but\s+was|Expected|Received)\b/i

    # path:line — the place to go next. UNANCHORED on purpose: rspec puts it in a
    # `# ./file.rb:41:in` comment, pytest at line start, and minitest inside
    # brackets mid-line (`TestMath#test_add [test/test_math.rb:12]:`). Requiring an
    # extension before the colon is what keeps it from matching prose like
    # "0.96 seconds" or "21 examples, 1 failure".
    LOCATION = %r{(?<loc>[\w./\-]+\.\w{1,10}:\d+)}

    # How much detail to carry under a marker. Enough for a stack's first frames,
    # short enough that the assertion stays on screen.
    WINDOW = 12

    def initialize(name: :failure)
      super(name: name)
    end

    # Only when there is a failure to foreground. A green run renders `output`.
    def applies?(node)
      return false unless FAILURE_TYPES.include?(node.type)

      failed_state?(node) || self.class.marked?(lines_of(node))
    end

    def panel(node, _workspace, now:)
      lines = lines_of(node)
      sections = []
      excerpt = self.class.excerpt(lines)
      sections << PanelSection.new(heading: "WHY IT FAILED", lines: excerpt) unless excerpt.empty?

      pair = lines.grep(EXPECTATION)
      sections << PanelSection.new(heading: "EXPECTED / ACTUAL", lines: pair) unless pair.empty?

      where = self.class.locations(lines)
      sections << PanelSection.new(heading: "WHERE", lines: where) unless where.empty?

      # Never render an empty panel: a node whose state says failed but whose output
      # says nothing recognisable still has to show SOMETHING, and the honest
      # something is the tail of what we captured.
      sections << PanelSection.new(heading: "OUTPUT (tail)", lines: lines.last(WINDOW)) if sections.empty?
      Panel.new(node: node, mode: name, sections: sections)
    end

    class << self
      def marked?(lines) = lines.any? { |l| l.match?(MARKER) }

      # The marker line plus the detail under it. Stops at the NEXT marker so a
      # multi-failure run shows the first failure whole rather than two halves.
      def excerpt(lines)
        start = start_index(lines)
        return [] unless start

        rest = lines[(start + 1)..] || []
        stop = [rest.index { |l| l.match?(MARKER) },        # the next failure
                dedent_index(rest, indent_of(lines[start])), # …or the end of this block
                WINDOW].compact.min
        [lines[start], *rest.first(stop)]
      end

      # Where the failure block ends: the first non-blank line that dedents PAST the
      # marker. A runner indents an assertion's detail under it and returns to
      # column 0 for the summary, so this drops the "Finished in… / N examples" tail
      # without a list of summary strings to keep current. Nil when the marker is
      # itself at column 0 (minitest) — nothing can dedent past it, so the window
      # governs and no chrome is guessed at.
      def dedent_index(lines, marker_indent)
        return nil if marker_indent.zero?

        lines.index { |l| !l.strip.empty? && indent_of(l) < marker_indent }
      end

      def indent_of(line) = line[/\A[ \t]*/].to_s.length

      # Prefer a marker that CARRIES something over a bare section header. rspec
      # prints `Failures:` as a banner and the real line (`Failure/Error: …`) two
      # lines down — starting at the banner spends the whole window on chrome and
      # then stops at the line you actually wanted. Falling back to the first marker
      # keeps minitest working, where the bare `Failure:` IS the marker and the
      # detail follows underneath.
      def start_index(lines)
        markers = lines.each_index.select { |i| lines[i].match?(MARKER) }
        return nil if markers.empty?

        markers.find { |i| contentful?(lines[i]) } || markers.first
      end

      # Anything left after the marker word besides punctuation.
      def contentful?(line)
        match = line.match(MARKER)
        !line[match.end(0)..].to_s.gsub(/[^[:alnum:]]/, "").empty?
      end

      def locations(lines)
        lines.filter_map { |l| l.match(LOCATION)&.[](:loc) }.uniq.first(3)
      end
    end

    private

    def failed_state?(node)
      node.properties[:state].to_s == "failed"
    end

    def lines_of(node)
      Array(node.properties[:output] || [node.name.to_s]).flat_map { |l| l.to_s.lines.map(&:chomp) }
    end
  end

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
