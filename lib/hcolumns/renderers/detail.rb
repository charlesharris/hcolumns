# frozen_string_literal: true

module HColumns
  module Renderers
    # The contextual inspector: everything about a node and how it got here — its
    # identity and properties, the edge(s) relating it, the confidence math broken
    # all the way down to each observation's reliability (base × decay × lens mix)
    # and how they fold (noisy-OR), and the lens-adjusted score behind its rank.
    #
    # Two entry points: `entry` inspects a column entry (a node reached by one edge
    # from the node you're walking — the TUI `i` key); `node` inspects a node in
    # the round, listing every edge into and out of it (the CLI `hcol inspect`).
    class Detail
      def entry(entry, from:, lens:, now:)
        lines = node_block(entry.target)
        lines << ""
        lines << "HOW IT GOT HERE"
        lines += edge_block(entry.edge, lens: lens, now: now,
                            from_name: name_of(from), target_name: entry.target.name)
        lines.join("\n")
      end

      def node(node, graph, lens:, now:)
        incoming = graph.edges_into(node.id)
        outgoing = graph.edges_from(node.id)

        lines = node_block(node)
        lines << ""
        lines << "HOW IT'S REACHED — incoming (#{incoming.size})"
        lines << "  (none)" if incoming.empty?
        incoming.each do |e|
          lines += edge_block(e, lens: lens, now: now,
                              from_name: name_of(graph.node(e.subject_id)), target_name: node.name)
        end
        lines << ""
        lines << "WHAT IT RELATES TO — outgoing (#{outgoing.size})"
        lines << "  (none)" if outgoing.empty?
        outgoing.each do |e|
          lines += edge_block(e, lens: lens, now: now,
                              from_name: node.name, target_name: name_of(graph.node(e.target_id)))
        end
        lines.join("\n")
      end

      private

      def name_of(node)
        node ? node.name : "?"
      end

      def node_block(node)
        ["NODE  #{node.name}",
         "  type        #{node.type}",
         "  id          #{node.id}",
         "  identity    #{node.identity[:scheme]} : #{node.identity[:key]}",
         "  properties  #{format_props(node.properties)}"]
      end

      def format_props(props)
        return "(none)" if props.nil? || props.empty?

        props.map { |k, v| "#{k}=#{v}" }.join("  ")
      end

      def edge_block(edge, lens:, now:, from_name:, target_name:)
        lines = ["  #{from_name} —#{edge.type}→ #{target_name}"]
        lines << "    maturity   #{edge.maturity(now: now)}"
        lines << score_line(edge, lens: lens, now: now)
        lines += confidence_lines(edge, lens: lens, now: now)
        lines += provenance_lines(edge, lens: lens, now: now)
        lines << ""
        lines
      end

      def score_line(edge, lens:, now:)
        wc = lens.tuner.weights[:confidence]
        wr = lens.tuner.weights[:recency]
        rel = lens.relation_weights.fetch(edge.type, 1.0)
        conf = lens.confidence(edge, now: now)
        rec = edge.recency(now: now)
        format("    score      %.3f = (conf %.2f × %.2g + recency %.2f × %.2g) × relation-weight %.2g   [lens: %s]",
               lens.score(edge, now: now), conf, wc, rec, wr, rel, lens.name)
      end

      def confidence_lines(edge, lens:, now:)
        mix = lens.tuner.evidence_mix
        conf = lens.confidence(edge, now: now)
        if edge.deterministic?
          [format("    confidence %.2f — deterministic (verifiable ground truth, pinned to 1.0)", conf)]
        else
          tag = mix.empty? ? "neutral mix" : "mix #{mix.inspect}"
          [format("    confidence %.3f = noisy-OR  1 − ∏(1−rᵢ)^wᵢ  over %d observation(s)  [%s]",
                  conf, edge.observations.size, tag)]
        end
      end

      def provenance_lines(edge, lens:, now:)
        mix = lens.tuner.evidence_mix
        lines = ["    provenance —"]
        edge.observations.each do |o|
          r = o.reliability(now: now, mix: mix)
          lines << format("      • [%s] w=%.2g  via %s  %s",
                          o.evidence_kind, o.weight, o.provider, age(o, now))
          lines << "        reliability #{reliability_detail(o, r, mix, now)}"
          lines << "        \"#{o.evidence_summary}\"" if o.evidence_summary
        end
        lines
      end

      def reliability_detail(obs, r, mix, now)
        if Evidence.deterministic?(obs.evidence_kind)
          format("%.3f — deterministic, pinned", r)
        else
          base = Evidence.reliability(obs.evidence_kind)
          decay = obs.decay(now: now)
          m = mix.fetch(obs.evidence_kind, 1.0)
          format("%.3f = base %.2f × decay %.2f × mix %.2g", r, base, decay, m)
        end
      end

      def age(obs, now)
        days = (now - obs.observed_at) / Evidence::DAY_SECONDS
        days < 1 ? "today" : "#{days.round}d ago"
      end
    end
  end
end
