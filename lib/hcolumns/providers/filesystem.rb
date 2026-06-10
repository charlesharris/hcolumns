# frozen_string_literal: true

module HColumns
  module Providers
    # On-demand filesystem provider. Expanding a directory node lists its
    # immediate children (one level — children are expanded only when navigated
    # to) and emits a CONTAINS observation per child. Hidden entries and common
    # heavy directories are skipped.
    class Filesystem
      IGNORE = %w[.git .hg .svn node_modules vendor tmp .bundle coverage].freeze

      def recognizes?(node)
        node.identity[:scheme] == "fs.path"
      end

      def expand(node, graph, now:)
        dir = self.class.path_of(node)
        return unless dir && File.directory?(dir)

        self.class.children(dir).each do |child_path|
          child = self.class.node_for(child_path)
          graph.add_node(child)
          graph.observe(Observation.new(
            provider: :filesystem, subject_id: node.id, target_id: child.id,
            edge_type: :CONTAINS, weight: 1.0, evidence_kind: :structure,
            observed_at: self.class.mtime(child_path, now), evidence_summary: "directory entry"
          ))
        end
      end

      class << self
        def node_for(path)
          abspath = File.expand_path(path)
          Node.new(
            type: type_of(abspath),
            identity: { scheme: "fs.path", key: "local:#{abspath}" },
            properties: { name: File.basename(abspath), path: abspath }
          )
        end

        def path_of(node)
          key = node.identity[:key]
          key&.start_with?("local:") ? key.sub("local:", "") : nil
        end

        def children(dir)
          Dir.children(dir).reject { |e| ignore?(e) }.sort.map { |e| File.join(dir, e) }
        rescue SystemCallError
          []
        end

        def ignore?(entry)
          entry.start_with?(".") || IGNORE.include?(entry)
        end

        def type_of(path)
          return :Directory if File.directory?(path)

          base = File.basename(path)
          case base
          when /(_spec|_test)\.rb\z/, /\Atest_.+\.rb\z/ then :TestFile
          when /\.rb\z/ then :SourceFile
          when /\.(md|markdown|rdoc|txt)\z/i then :Doc
          else :File
          end
        end

        def mtime(path, fallback)
          File.mtime(path)
        rescue SystemCallError
          fallback
        end
      end
    end
  end
end
