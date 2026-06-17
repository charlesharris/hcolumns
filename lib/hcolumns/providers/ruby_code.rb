# frozen_string_literal: true

require "ripper"

module HColumns
  module Providers
    # On-demand Ruby code-structure provider. It makes the graph aware of what is
    # *inside* a file, not just files as opaque blobs, using Ruby's stdlib parser
    # (Ripper — a real AST, zero gems). Three relations, all language-scoped to .rb:
    #
    #   DEFINES     file  -> Class/Module it defines  (drill in -> its methods)
    #               Class -> the methods it owns       (+ a DEFINED_IN back-edge)
    #   DEPENDS_ON  file  -> file it require[_relative]s, when that resolves locally
    #   REFERENCES  file  -> a constant defined elsewhere in the repo
    #
    # DEFINES / require_relative are deterministic facts (structure evidence). A
    # bare `require` and every REFERENCES edge lean on heuristic resolution against
    # a repo-wide constant index, so they are tagged inference (lower trust, decays).
    #
    # Cross-file REFERENCES need to resolve a bare `Foo` to wherever Foo is defined,
    # so the provider builds one bounded, cached constant index of the repo the
    # first time a reference is resolved. This is the one un-lazy cost here; it is
    # built at most once per Workspace and capped at MAX_INDEX_FILES.
    class RubyCode
      MAX_INDEX_FILES = 2000

      def initialize(root)
        @root = root && File.expand_path(root)
        @cache = {}   # abspath -> Analyzer (parsed once, reused across expansions)
      end

      def recognizes?(node)
        case node.identity[:scheme]
        when "fs.path"
          path = Filesystem.path_of(node)
          path && File.file?(path) && path.end_with?(".rb") && within_root?(path)
        when "ruby.const"
          path = node.properties[:path]
          path && File.file?(path) && within_root?(path)
        else
          false
        end
      end

      def expand(node, graph, now:)
        case node.identity[:scheme]
        when "fs.path"   then expand_file(node, graph, now: now)
        when "ruby.const" then expand_const(node, graph, now: now)
        end
      end

      private

      # A .rb file -> the consts it defines, the files it depends on, and the
      # external constants it references.
      def expand_file(node, graph, now:)
        path = Filesystem.path_of(node)
        a = analyze(path)
        return unless a

        at = Filesystem.mtime(path, now)
        define_consts(node, graph, definition_consts(a), path, at)
        define_methods(node, graph, a.methods.select { |m| m[:owner].nil? }, nil, path, at)
        emit_requires(node, graph, a, path, at)
        emit_references(node, graph, a, path, at)
      end

      # A Class/Module node -> the methods and nested consts it owns, plus a back
      # edge to the file it lives in. Re-parses the owning file (cached).
      def expand_const(node, graph, now:)
        qname = node.properties[:qualified_name] || node.identity[:key]
        path = node.properties[:path]
        a = analyze(path)
        return unless a

        at = Filesystem.mtime(path, now)
        children = a.consts.select { |c| parent_of(c[:qname]) == qname }
        define_consts(node, graph, children, path, at)
        define_methods(node, graph, a.methods.select { |m| m[:owner] == qname }, qname, path, at)

        file = graph.add_node(Filesystem.node_for(path))
        observe(graph, node.id, file.id, :DEFINED_IN, 1.0, :structure, at,
                "defined in #{File.basename(path)}")
      end

      def define_consts(node, graph, consts, path, at)
        consts.each do |c|
          target = graph.add_node(const_node(c[:qname], path, c[:kind]))
          observe(graph, node.id, target.id, :DEFINES, 1.0, :structure, at,
                  "defines #{c[:kind].to_s.downcase} #{c[:qname]}")
        end
      end

      def define_methods(node, graph, methods, owner, path, at)
        methods.each do |m|
          target = graph.add_node(method_node(owner, m[:name], m[:singleton], path))
          observe(graph, node.id, target.id, :DEFINES, 1.0, :structure, at,
                  "defines method #{sep(m[:singleton])}#{m[:name]}")
        end
      end

      def emit_requires(node, graph, analyzer, path, at)
        analyzer.requires.each do |req|
          dep = resolve_require(req, from: path)
          next unless dep

          target = graph.add_node(Filesystem.node_for(dep))
          kind = req[:relative] ? :structure : :inference
          verb = req[:relative] ? "require_relative" : "require"
          observe(graph, node.id, target.id, :DEPENDS_ON, 1.0, kind, at, "#{verb} #{req[:name].inspect}")
        end
      end

      def emit_references(node, graph, analyzer, path, at)
        reference_counts(analyzer).each do |name, count|
          res = resolve_ref(name)
          next unless res && res[:path] != path # skip unresolved + same-file refs

          target = graph.add_node(const_node(res[:qname], res[:path], res[:kind]))
          observe(graph, node.id, target.id, :REFERENCES, count.to_f, :inference, at,
                  "references #{res[:qname]} (#{count}×)")
        end
      end

      # Consts referenced but not defined in this file, with mention counts.
      def reference_counts(analyzer)
        defined = analyzer.consts.map { |c| c[:qname] }
        analyzer.refs.each_with_object(Hash.new(0)) do |name, acc|
          acc[name] += 1 unless defined.include?(name)
        end
      end

      # The substantive consts a file defines: the first real Class/Module on each
      # branch, seen *through* pure namespace wrappers. `module HColumns; module
      # Providers; class RubyCode` defines RubyCode — HColumns/Providers are just
      # namespaces, and RubyCode's own nested Analyzer is found by drilling in.
      def definition_consts(analyzer)
        by_qname = analyzer.consts.to_h { |c| [c[:qname], c] }
        owners = analyzer.methods.filter_map { |m| m[:owner] }
        analyzer.consts.reject do |c|
          namespace?(c, by_qname, owners) || ancestor_substantive?(c[:qname], by_qname, owners)
        end
      end

      # A Module that holds no methods of its own and only wraps nested consts —
      # transparent, not a definition in its own right.
      def namespace?(const, by_qname, owners)
        const[:kind] == :Module && !owners.include?(const[:qname]) &&
          by_qname.keys.any? { |q| parent_of(q) == const[:qname] }
      end

      # True if any in-file ancestor of qname is itself a real definition (so qname
      # is nested inside it and should surface only by drilling into that ancestor).
      def ancestor_substantive?(qname, by_qname, owners)
        parent = parent_of(qname)
        return false if parent.empty?

        pc = by_qname[parent]
        return ancestor_substantive?(parent, by_qname, owners) unless pc # defined elsewhere: transparent

        !namespace?(pc, by_qname, owners) || ancestor_substantive?(parent, by_qname, owners)
      end

      def resolve_require(req, from:)
        if req[:relative]
          cand = File.expand_path("#{req[:name]}.rb", File.dirname(from))
          File.file?(cand) ? cand : nil
        elsif @root
          # Heuristic load-path resolution: the common gem layout (lib/) and root.
          %w[lib .].each do |sub|
            cand = File.expand_path("#{req[:name]}.rb", File.join(@root, sub))
            return cand if File.file?(cand)
          end
          nil
        end
      end

      # Resolve a referenced constant name to a definition in the repo index:
      # exact qname first, else the shortest qname ending in "::name".
      def resolve_ref(name)
        if (hit = index[name])
          { qname: name, path: hit[:path], kind: hit[:kind] }
        else
          suffix = "::#{name}"
          q = index.keys.select { |k| k.end_with?(suffix) }.min_by { |k| [k.length, k] }
          q && { qname: q, path: index[q][:path], kind: index[q][:kind] }
        end
      end

      def index
        @index ||= build_index
      end

      def build_index
        return {} unless @root

        ruby_files.each_with_object({}) do |file, idx|
          a = analyze(file) or next
          a.consts.each { |c| idx[c[:qname]] ||= { path: file, kind: c[:kind] } }
        end
      end

      def ruby_files
        Dir.glob(File.join(@root, "**", "*.rb"))
           .reject { |f| f.split("/").any? { |seg| Filesystem::IGNORE.include?(seg) } }
           .sort
           .first(MAX_INDEX_FILES)
      end

      def analyze(path)
        return nil unless path && File.file?(path)

        @cache.fetch(path) do
          @cache[path] =
            begin
              Analyzer.analyze(File.read(path))
            rescue StandardError
              nil
            end
        end
      end

      def const_node(qname, path, kind)
        Node.new(
          type: kind,
          identity: { scheme: "ruby.const", key: qname },
          properties: { name: qname.split("::").last, qualified_name: qname, path: path }
        )
      end

      def method_node(owner, name, singleton, path)
        Node.new(
          type: :Method,
          identity: { scheme: "ruby.method", key: "#{owner}#{sep(singleton)}#{name}" },
          properties: { name: "#{sep(singleton)}#{name}", method: name, owner: owner,
                        singleton: singleton, path: path }
        )
      end

      def observe(graph, subject_id, target_id, type, weight, kind, at, summary)
        graph.observe(Observation.new(
          provider: :ruby, subject_id: subject_id, target_id: target_id, edge_type: type,
          weight: weight, evidence_kind: kind, observed_at: at, evidence_summary: summary
        ))
      end

      def within_root?(path)
        @root.nil? || path == @root || path.start_with?("#{@root}/")
      end

      def parent_of(qname)
        qname.include?("::") ? qname.rpartition("::").first : ""
      end

      def sep(singleton)
        singleton ? "." : "#"
      end

      # Walks a Ripper S-expression once, collecting the constants and methods a
      # file defines (with their lexical scope), the files it requires, and the
      # constants it references. Tree-driven (not the event API) so we can keep a
      # module/class nesting stack as we descend.
      class Analyzer
        attr_reader :requires, :consts, :methods, :refs

        def self.analyze(source)
          tree = Ripper.sexp(source)
          new.tap { |a| a.send(:walk, tree, "") if tree }
        end

        def initialize
          @requires = []
          @consts = []
          @methods = []
          @refs = []
        end

        private

        def walk(node, scope)
          return unless node.is_a?(Array)

          case node[0]
          when :class
            return enter_const(node, scope, :Class, name: node[1], superclass: node[2], body: node[3])
          when :module
            return enter_const(node, scope, :Module, name: node[1], body: node[2])
          when :def
            record_method(scope, ident_string(node[1]), singleton: false)
          when :defs
            record_method(scope, ident_string(node[3]), singleton: true)
          when :command, :command_call, :method_add_arg
            record_require(node)
          when :var_ref, :top_const_ref, :const_path_ref
            name = const_string(node)
            @refs << name if name
            return # don't descend: would double-count the const path's base
          end

          node.each { |child| walk(child, scope) if child.is_a?(Array) }
        end

        def enter_const(_node, scope, kind, name:, body:, superclass: nil)
          qname = const_string(name)
          return unless qname

          full = join(scope, qname)
          @consts << { qname: full, kind: kind }
          walk(superclass, scope) if superclass # a superclass is a reference
          walk(body, full)                       # body in the nested scope
        end

        def record_method(scope, name, singleton:)
          return unless name

          @methods << { owner: scope.empty? ? nil : scope, name: name, singleton: singleton }
        end

        def record_require(node)
          ident, args =
            case node[0]
            when :command then [ident_string(node[1]), node[2]]
            when :method_add_arg
              fcall = node[1]
              fcall.is_a?(Array) && fcall[0] == :fcall ? [ident_string(fcall[1]), node[2]] : [nil, nil]
            else [nil, nil]
            end
          return unless %w[require require_relative].include?(ident)

          str = first_tstring(args)
          @requires << { name: str, relative: ident == "require_relative" } if str
        end

        def const_string(node)
          return nil unless node.is_a?(Array)

          case node[0]
          when :@const then node[1]
          when :const_ref, :top_const_ref, :var_ref then const_string(node[1])
          when :const_path_ref, :const_path_field
            base = const_string(node[1])
            tail = const_string(node[2])
            base && tail ? "#{base}::#{tail}" : tail
          end
        end

        def ident_string(node)
          node.is_a?(Array) && node[1].is_a?(String) ? node[1] : nil
        end

        # The first plain string literal inside a require's argument sexp (skips
        # interpolated/dynamic requires, which have no single literal target).
        def first_tstring(node)
          return nil unless node.is_a?(Array)
          return node[1] if node[0] == :@tstring_content

          node.each do |child|
            found = first_tstring(child)
            return found if found
          end
          nil
        end

        def join(scope, name)
          scope.empty? ? name : "#{scope}::#{name}"
        end
      end
    end
  end
end
