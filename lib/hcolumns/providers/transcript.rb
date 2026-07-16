# frozen_string_literal: true

require "json"

module HColumns
  module Providers
    # On-demand transcript provider (hc-33x) — the **context stratum**: what the
    # session's tokens actually WERE, and where they went.
    #
    # The measurement that shapes this whole design: a real session sent 102.9M
    # wire tokens against only 2.8MB (~700k tokens) of DISTINCT content on disk —
    # a ~100x re-read factor, because every turn re-sends the accreted mound
    # through the cache. So "show me all the actual tokens" is tractable: the
    # corpus is ~700k, not 102.9M. And the cost of a block is dominated by how
    # long it SITS in context, not its size — one 14.5k-token file read stayed
    # resident for 531 turns and outcost a block twice its size by 6x. Ranking by
    # size tells the wrong story; we rank by size x residency, cache-weighted.
    #
    # Format-awareness lives HERE, deliberately. hcolumns' core (the graph, the
    # log, the bridge vocabulary) stays agent-agnostic; a provider is exactly the
    # layer that knows a foreign format — Git knows git's output, Beads knows the
    # dolt wire, and Transcript knows Claude Code's JSONL. The bridge only ever
    # learns the *pointer* (a `transcript <path>` verb), because a path is the one
    # thing the hook knows and the graph can't re-derive.
    #
    # Nothing here is folded into the bridge log. The transcript is re-derivable
    # from disk, so this follows the content-tab precedent (layers 21-24): blocks
    # are minted lazily on expansion, and a block's TEXT is never held in the
    # graph at all — the node carries a line pointer and the facet reads it back
    # on demand. A 2.8MB transcript (or a 20MB one) costs the graph a few KB.
    class Transcript
      # A block's tokens are ESTIMATED (bytes/4 — no tokenizer, and the gem has no
      # runtime deps). The transcript's per-message `usage` is a whole-context
      # total, not a per-block attribution, so it can't be divided honestly. The
      # estimate is good to ~30% against billed totals, which is plenty to rank —
      # and it is reported as an estimate rather than dressed up as truth.
      BYTES_PER_TOKEN = 4

      # Anthropic's cache multipliers, relative to base input price: a block is
      # WRITTEN to the cache once (1.25x) and then RE-READ on every later turn at
      # a tenth of base (0.1x). Measured across our own 12 sessions: 98% of wire
      # volume is cache reads, so raw wire tokens overstate real cost by ~8x
      # (685.4M wire → 82.6M cost-equivalent). Ranking is nearly unaffected — the
      # 0.1x·residency term dominates — but the NUMBER has to be honest, or the
      # view invites you to panic about a bill you never paid.
      # https://platform.claude.com/docs/en/build-with-claude/prompt-caching
      CACHE_WRITE = 1.25
      CACHE_READ = 0.1

      # The kinds of block worth being a node. `thinking` earns its place: it is
      # the largest category on disk (376KB of the 2.8MB) and takes 6 of the top
      # 10 cost slots — excluding it would make the cost picture visibly fail to
      # add up.
      KINDS = %w[thinking text tool_use tool_result].freeze

      class << self
        def recognizes?(node)
          %w[agent.transcript transcript.block].include?(node.identity[:scheme])
        end

        def expand(node, graph, now:)
          case node.identity[:scheme]
          when "agent.transcript" then expand_transcript(node, graph, now: now)
          when "transcript.block" then expand_block(node, graph, now: now)
          end
        end

        # The Transcript node itself — the anchor the bridge's `transcript` verb
        # emits and this provider expands. Keyed by path, so the same transcript
        # reached from any session is the same node.
        def node_for(path)
          Node.new(type: :Transcript, identity: { scheme: "agent.transcript", key: path },
                   properties: { name: "context (#{File.basename(path, '.jsonl')[0, 8]})", path: path })
        end

        # Read a block's text back on demand (the content facet's source). Returns
        # lines, like Git.show — the panel renders lines.
        def text_for(node, limit: 600)
          path = node.properties[:path]
          line_no = node.properties[:line]
          return ["(transcript unavailable)"] unless path && line_no && File.file?(path)

          entry = read_line(path, line_no)
          block = entry && Array(entry.dig("message", "content"))[node.properties[:block_index].to_i]
          return ["(block unavailable)"] unless block

          body_of(block).to_s.lines.map(&:chomp).first(limit)
        end

        private

        # One pass over the transcript: every block becomes a node, ranked by an
        # estimated billed cost. `resident` is the number of assistant turns that
        # re-read this block after it landed — the multiplier that makes an early
        # block expensive and a late one cheap.
        def expand_transcript(node, graph, now:)
          path = node.properties[:path]
          return unless path && File.file?(path)

          blocks = scan(path)
          return if blocks.empty?

          total_turns = blocks.map { |b| b[:turn] }.max.to_i
          blocks.each do |block|
            block[:resident] = total_turns - block[:turn]
            # Cost-EQUIVALENT (base-input-priced), not wire volume: written once,
            # then re-read cheaply on every later turn.
            block[:cost] = (block[:tokens] * (CACHE_WRITE + (CACHE_READ * block[:resident]))).round
            block[:wire] = block[:tokens] * (block[:resident] + 1)
          end

          blocks.each { |block| add_block(graph, node, block, path, now: now) }
        end

        def add_block(graph, transcript, block, path, now:)
          target = graph.add_node(block_node(block, path, transcript.identity[:key]))
          # The block's EXISTENCE is verifiable ground truth (it is really in the
          # transcript) — but its cost is a MODEL (estimated tokens x residency),
          # so the edge carries :inference, not :structure. The evidence discipline
          # is the point: confidence reports how much we actually know.
          observe(graph, transcript, target, :CONSUMED, weight: 1.0, kind: :inference, at: now,
                  summary: "~#{approx(block[:tokens])} tok × #{block[:resident]} turns resident " \
                           "≈ #{approx(block[:cost])} cost-equiv (estimated; cache-weighted)")
        end

        # The anchor (Charris's call): a Read's result is content that is ALREADY
        # an fs.path node — so point at that node instead of re-indexing its words.
        # The payoff runs backwards too: a file's details now answer "this file
        # cost me 7.7M", because the incoming edge is right there.
        def expand_block(node, graph, now:)
          path = node.properties[:file]
          return unless path && File.exist?(path)

          target = graph.add_node(Filesystem.node_for(path))
          observe(graph, node, target, :READS, weight: 1.0, kind: :structure, at: now,
                  summary: "read #{File.basename(path)} into context")
        end

        def block_node(block, path, key)
          Node.new(
            type: :ContextBlock,
            identity: { scheme: "transcript.block", key: "#{key}\x1f#{block[:line]}:#{block[:index]}" },
            properties: { name: block[:label], kind: block[:kind], tokens: block[:tokens],
                          resident: block[:resident], cost: block[:cost], wire: block[:wire],
                          turn: block[:turn], body: block[:body], command: block[:command],
                          path: path, line: block[:line], block_index: block[:index],
                          file: block[:file] }
          )
        end

        # Walk the JSONL once, emitting one hash per content block. Turn numbers
        # come from assistant messages carrying usage (a billed round-trip), which
        # is the same boundary the hook's usage slice uses.
        #
        # `calls` correlates a tool_result back to the tool_use that caused it
        # (by tool_use_id). Without it the most expensive rows in the whole view
        # are labelled "result" and anchor to nothing — a result block carries no
        # input of its own, so everything that makes it legible (which tool, which
        # file) lives on the call, one message earlier.
        def scan(path)
          blocks = []
          calls = {}
          turn = 0
          seen = nil
          each_entry(path) do |entry, line_no|
            # A turn is one API ROUND-TRIP, not one transcript entry: a single
            # response is written as several entries (one per content block), each
            # repeating the same usage and the same message id. Counting entries
            # inflated residency by however many blocks a reply happened to have
            # (~2.2x measured). message.id is the response's identity.
            id = entry.dig("message", "id")
            if entry["type"] == "assistant" && entry.dig("message", "usage") && id != seen
              turn += 1
              seen = id
            end
            next if entry["isSidechain"]

            Array(entry.dig("message", "content")).each_with_index do |block, index|
              calls[block["id"]] = block if block.is_a?(Hash) && block["type"] == "tool_use" && block["id"]
              next unless block.is_a?(Hash) && KINDS.include?(block["type"])

              blocks << describe(block, entry, turn, line_no, index, calls[block["tool_use_id"]])
            end
          end
          blocks
        end

        def describe(block, entry, turn, line_no, index, call)
          { kind: block["type"], turn: turn, line: line_no, index: index,
            tokens: (JSON.generate(block).bytesize / BYTES_PER_TOKEN),
            label: label_for(block, entry, turn, call), file: file_of(block, call),
            body: digest(fingerprint_of(block)), command: call&.dig("input", "command") }
        end

        # A cheap content fingerprint (djb2, the AgentBridge digest) so the advice
        # rules can spot the same bytes arriving twice — the largest waste pattern
        # we measured (13.3% of cost within a session).
        #
        # Fingerprints the CONTENT, not the rendered text and not the whole block:
        # two reads of one file must match despite different tool_use_ids, but an
        # IMAGE has no text at all — rendering it gave "", so every image and every
        # empty result collided into one bogus 56x "duplicate" group. Images are
        # the biggest blocks we have (~53k tok), so that false positive landed
        # exactly where it did the most damage.
        def fingerprint_of(block)
          case block["type"]
          when "tool_result" then JSON.generate(block["content"])
          when "tool_use" then JSON.generate(block["input"])
          else body_of(block).to_s
          end
        end

        def digest(text)
          text.each_char.reduce(5381) { |h, ch| ((h * 33) ^ ch.ord) & 0xffffffff }.to_s(16)
        end

        # What the row says. A tool call names the tool and its target; a result
        # names the CALL that produced it (from `call`, since a result block knows
        # nothing about itself); thinking/text name their turn — enough to know
        # what you are looking at before you descend into it.
        def label_for(block, entry, turn, call)
          case block["type"]
          when "tool_use" then "#{block['name']}(#{short_target(block['input'])})"
          when "tool_result" then call ? "#{call['name']}(#{short_target(call['input'])})" : "result"
          when "thinking" then "thinking (turn #{turn})"
          else entry["type"] == "user" ? "prompt (turn #{turn})" : "reply (turn #{turn})"
          end
        end

        def short_target(input)
          return "" unless input.is_a?(Hash)

          value = input["file_path"] || input["notebook_path"] || input["command"] || input["pattern"] || ""
          value = File.basename(value) if value.include?("/") && !value.include?(" ")
          value.to_s.gsub(/\s+/, " ")[0, 40]
        end

        # The anchor's source: a call's own input, or — for a result — the input of
        # the call that produced it. Only a real, absolute path anchors: a relative
        # one would mint an fs.path node against the serving process's cwd, which
        # is not where the session ran.
        def file_of(block, call)
          input = block["input"] || call&.fetch("input", nil)
          return nil unless input.is_a?(Hash)

          path = input["file_path"] || input["notebook_path"]
          path if path.is_a?(String) && path.start_with?("/")
        end

        def each_entry(path)
          line_no = 0
          File.foreach(path) do |line|
            line_no += 1
            entry = begin
              JSON.parse(line)
            rescue JSON::ParserError
              next
            end
            yield entry, line_no
          end
        end

        def read_line(path, line_no)
          File.foreach(path).with_index(1) do |line, index|
            next unless index == line_no

            return begin
              JSON.parse(line)
            rescue JSON::ParserError
              nil
            end
          end
          nil
        end

        # A block's renderable body, by kind.
        def body_of(block)
          case block["type"]
          when "thinking" then block["thinking"]
          when "text" then block["text"]
          when "tool_use" then JSON.pretty_generate(block["input"])
          when "tool_result" then stringify(block["content"])
          end
        end

        def stringify(content)
          return content if content.is_a?(String)

          Array(content).filter_map { |b| b["text"] if b.is_a?(Hash) }.join("\n")
        end

        def approx(count)
          return "#{(count / 1_000_000.0).round(1)}M" if count >= 1_000_000
          return "#{(count / 1_000.0).round(1)}k" if count >= 1_000

          count.to_s
        end

        def observe(graph, subject, target, type, weight:, kind:, at:, summary:)
          graph.observe(Observation.new(
                          provider: :transcript, subject_id: subject.id, target_id: target.id,
                          edge_type: type, weight: weight, evidence_kind: kind,
                          observed_at: at, evidence_summary: summary
                        ))
        end
      end
    end
  end
end
