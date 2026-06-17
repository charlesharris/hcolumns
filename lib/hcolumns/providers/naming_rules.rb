# frozen_string_literal: true

module HColumns
  module Providers
    # On-demand naming-rule provider: a crisp source<->test PAIR, computed by
    # string transform (no scanning) and confirmed by File.exist?. Covers the
    # common Ruby conventions — co-located `foo_spec.rb`/`foo_test.rb`, and the
    # lib/ <-> spec/ or test/ mirror. Heuristic by nature; deliberately modest.
    class NamingRules
      def recognizes?(node)
        path = Filesystem.path_of(node)
        path ? File.file?(path) : false
      end

      def expand(node, graph, now:)
        path = Filesystem.path_of(node)
        return unless path && File.file?(path)

        partners(path).each do |partner|
          next unless File.exist?(partner)

          other = Filesystem.node_for(partner)
          graph.add_node(other)
          graph.observe(Observation.new(
            provider: :naming, subject_id: node.id, target_id: other.id,
            edge_type: :PAIR, weight: 1.0, evidence_kind: :convention,
            observed_at: now, evidence_summary: "source/test naming pair"
          ))
        end
      end

      private

      def partners(path)
        return [] unless File.extname(path) == ".rb"

        dir = File.dirname(path)
        base = File.basename(path, ".rb")
        candidates =
          if base.end_with?("_spec", "_test")
            stem = base.sub(/_(spec|test)\z/, "")
            [File.join(dir, "#{stem}.rb"),
             File.join(swap_segment(dir, "spec", "lib"), "#{stem}.rb"),
             File.join(swap_segment(dir, "test", "lib"), "#{stem}.rb")]
          else
            [File.join(dir, "#{base}_spec.rb"),
             File.join(dir, "#{base}_test.rb"),
             File.join(swap_segment(dir, "lib", "spec"), "#{base}_spec.rb"),
             File.join(swap_segment(dir, "lib", "test"), "#{base}_test.rb")]
          end
        candidates.map { |c| File.expand_path(c) }.uniq
      end

      # Replace a whole path segment (e.g. lib -> spec) without matching substrings.
      def swap_segment(dir, from, to)
        dir.gsub(%r{(?<=/|\A)#{Regexp.escape(from)}(?=/|\z)}, to)
      end
    end
  end
end
