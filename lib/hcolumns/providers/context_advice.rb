# frozen_string_literal: true

module HColumns
  module Providers
    # The dictionary of token dark patterns (hc-bnh) — advice attached to the
    # blocks that cost the most.
    #
    # Every rule here was SEEDED FROM MEASUREMENT, not folklore: each names the
    # share of real cost it accounts for across our own 12 transcripts (6313
    # blocks, 28.3M cost-equivalent, round-trip turns, cache-weighted).
    #
    # THREE candidates were killed by that same data and are deliberately absent.
    # A rule that fires on nothing is worse than no rule — it teaches you to
    # ignore the panel:
    #
    #   * "error results are expensive" — 0.1%. Noise.
    #   * cache-thrash from >=12 parallel tool calls (widely cited, single-source):
    #     its precondition has never once occurred here. Max parallel calls we
    #     have EVER issued is 3.
    #   * "the same content gets re-read" — the pattern this dictionary was
    #     originally built around, and it evaporated under measurement. First
    #     estimated at 18.3% of all cost, headlined by "one PNG read 8 times".
    #     Both were artifacts: grouping ran ACROSS sessions (a file read once in
    #     each of eight sessions is eight necessary reads, not seven wasted ones →
    #     13.3%), and the fingerprint rendered a block to its TEXT, so images —
    #     which have none — all collided into one bogus group (→ 1.3%). The "PNG
    #     read 8 times" was eight DIFFERENT screenshots, each read once, while
    #     writing the README. What survives at 1.3% is mostly boilerplate: 39
    #     identical "file has been updated" acks. Not waste. The fingerprint fix
    #     is kept (Transcript#fingerprint_of) because it was a real bug; the rule
    #     is not, because the pattern is not real.
    #
    # Advice is a CLAIM, never a fact. So a suggestion is :inference evidence with
    # a confidence below 1.0, and bad advice SINKS in the ranking rather than
    # needing to be hidden — the flags posture (re-weight, don't toggle). The
    # block's cost is what it is; whether it was avoidable is an opinion.
    #
    # Savings are quoted in COST-EQUIVALENT, never wire volume. Wire overstates
    # the bill ~8x (a re-read bills at 0.1x), and a recommendation that inflates
    # its own payoff eightfold is a lie in the user's favour, which is worse.
    class ContextAdvice
      # A rule: `when` decides, `advice` explains, `saving` quantifies, `fix` is
      # the prompt an agent could act on (hc-bnh's dispatch half).
      Rule = Struct.new(:key, :title, :when, :advice, :saving, :fix, keyword_init: true)

      MIN_COST = 2_000 # below this a suggestion is noise, whatever the pattern

      RULES = [
        # 13.2% — the STATUS.md shape: big, early, resident for the whole session.
        # The largest real pattern we found.
        Rule.new(
          key: :early_large_read,
          title: "large read landed early and was re-sent all session",
          when: lambda { |b, ctx|
            b.properties[:kind] == "tool_result" && b.properties[:tokens].to_i > 2_000 &&
              b.properties[:resident].to_i > (ctx[:turns] * 0.5)
          },
          advice: lambda { |b, _|
            "#{b.properties[:tokens]} tokens landed at turn #{b.properties[:turn]} and were re-sent " \
              "for #{b.properties[:resident]} turns after. Read the section you need (offset/limit), " \
              "or grep first — a targeted read beats vector retrieval (arXiv:2605.15184)."
          },
          # Reading a quarter of it, later, is the realistic counterfactual.
          saving: ->(b, _) { (b.properties[:cost].to_i * 0.75).round },
          fix: lambda { |b, _|
            "#{b.properties[:name]} pulled #{b.properties[:tokens]} tokens into context at turn " \
              "#{b.properties[:turn]}. Propose a narrower way to get the same information — a grep, " \
              "an offset/limit window, or deferring the read until it is needed."
          }
        ),

        # 20.4% of cost sits in the ~8% of thinking blocks over 2k tokens.
        # Measured, not assumed: thinking IS retained and re-sent (361/361 pairs).
        Rule.new(
          key: :long_thinking,
          title: "a long reasoning block, re-sent every turn after",
          when: lambda { |b, ctx|
            b.properties[:kind] == "thinking" && b.properties[:tokens].to_i > 2_000 &&
              b.properties[:resident].to_i > (ctx[:turns] * 0.25)
          },
          advice: lambda { |b, _|
            "#{b.properties[:tokens]} tokens of reasoning, resident #{b.properties[:resident]} turns. " \
              "Prior-turn thinking is NOT stripped — it is re-sent every turn (measured 361/361). " \
              "Long deliberation early is paid for all session; the fix is the agent's, not yours."
          },
          saving: ->(b, _) { (b.properties[:cost].to_i * 0.5).round },
          fix: nil # nothing a code change can do — reported for honesty, not action
        ),

        # 1.0% — a `cat`/unpiped command where head/grep would do. Small, but
        # cheap to detect and trivially actionable, so it earns its place.
        Rule.new(
          key: :unpiped_output,
          title: "command output arrived whole",
          when: lambda { |b, _|
            b.properties[:kind] == "tool_result" && b.properties[:file].nil? &&
              b.properties[:tokens].to_i > 800 &&
              !b.properties[:command].to_s.match?(/\|\s*(head|tail|grep|wc|jq)\b/)
          },
          advice: lambda { |b, _|
            "#{b.properties[:tokens]} tokens of output with no head/grep in the command. " \
              "Pipe it — the whole dump is re-sent every turn after this one."
          },
          saving: ->(b, _) { (b.properties[:cost].to_i * 0.8).round },
          fix: lambda { |b, _|
            "This command dumped #{b.properties[:tokens]} tokens into context:\n\n  " \
              "#{b.properties[:command]}\n\nPropose a narrower form that answers the same question."
          }
        )
      ].freeze

      class << self
        def recognizes?(node)
          node.identity[:scheme] == "agent.transcript"
        end

        # Suggestions hang off the TRANSCRIPT (so they rank together as "the fixes
        # worth making") and point AT the block they are about — Charris's ask:
        # clickable, with the association being a real edge to the real cost.
        def expand(node, graph, now:)
          blocks = graph.edges_from(node.id).select { |e| e.type == :CONSUMED }
                        .filter_map { |e| graph.node(e.target_id) }
          return if blocks.empty?

          ctx = context_for(blocks)
          blocks.each { |block| suggest_for(block, node, graph, ctx, now: now) }
        end

        private

        # Session-wide facts a rule needs. Only the turn count survives the rules
        # above; if a future rule needs cross-block context it goes here, and it
        # must be scoped to THIS transcript — measuring across sessions conflates
        # separate contexts, which is half of how the duplicate-content rule
        # fooled us.
        def context_for(blocks)
          { turns: blocks.map { |b| b.properties[:turn].to_i }.max.to_i }
        end

        def suggest_for(block, transcript, graph, ctx, now:)
          return if block.properties[:cost].to_i < MIN_COST

          RULES.each do |rule|
            next unless rule.when.call(block, ctx)

            saving = rule.saving.call(block, ctx)
            next if saving < MIN_COST

            emit(rule, block, transcript, graph, ctx, saving, now: now)
          end
        end

        def emit(rule, block, transcript, graph, ctx, saving, now:)
          node = graph.add_node(suggestion_node(rule, block, ctx, saving))
          # The suggestion is ABOUT the block: click through to the cost it names.
          observe(graph, node, block, :ABOUT, kind: :structure, at: now,
                  summary: "the block this is about")
          # …and the transcript OFFERS it. :inference — this is advice, not fact.
          observe(graph, transcript, node, :SUGGESTS, kind: :inference, at: now,
                  summary: "#{rule.key}: could save ~#{approx(saving)} cost-equiv (estimated)")
        end

        def suggestion_node(rule, block, ctx, saving)
          Node.new(
            type: :Suggestion,
            identity: { scheme: "context.suggestion", key: "#{block.id}\x1f#{rule.key}" },
            properties: { name: "#{rule.title} (~#{approx(saving)})", rule: rule.key,
                          saving: saving, advice: rule.advice.call(block, ctx),
                          fix: rule.fix&.call(block, ctx), subject: block.id,
                          path: block.properties[:file] }
          )
        end

        def approx(count)
          return "#{(count / 1_000_000.0).round(1)}M" if count >= 1_000_000
          return "#{(count / 1_000.0).round(1)}k" if count >= 1_000

          count.to_s
        end

        def observe(graph, subject, target, type, kind:, at:, summary:)
          graph.observe(Observation.new(
                          provider: :advice, subject_id: subject.id, target_id: target.id,
                          edge_type: type, weight: 1.0, evidence_kind: kind,
                          observed_at: at, evidence_summary: summary
                        ))
        end
      end
    end
  end
end
