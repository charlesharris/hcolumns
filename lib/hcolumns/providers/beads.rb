# frozen_string_literal: true

require "json"

module HColumns
  module Providers
    # On-demand beads provider — a project's beads issue database (Yegge's `bd`)
    # rendered as columns. Beads is already a property graph: issues are nodes,
    # the `dependencies` table is typed directed edges (parent-child, blocks,
    # related, discovered-from, …), so the mapping is nearly 1:1.
    #
    #   * the beads root dir -> HAS_BEADS -> a Beads index node
    #   * the index          -> HAS_BEAD  -> each issue (bounded)
    #   * a Bead             -> HAS_CHILD / CHILD_OF / BLOCKS / BLOCKED_BY /
    #                           RELATED / DISCOVERED_FROM / … from the deps table,
    #                           plus TOUCHES -> real fs.path file nodes
    #
    # The integration posture (decided with Charris, hc-ux6): an active *client*
    # of the dolt database — a persistent MySQL-wire connection, not `bd`
    # subprocess-per-column. The endpoint is resolved from the repo's `.beads`
    # state (shared-server flag + port files), never assumed.
    #
    # Evidence honesty: declared structure (dependency rows) is verifiable ground
    # truth -> :structure 1.0. File links are not first-class in beads — a file
    # list in the issue's `metadata` JSON is an agent's assertion -> :agent; a
    # path scraped out of description/design prose is a guess -> :inference.
    #
    # Soft dependency: the MySQL client (pure-Ruby `ruby-mysql` gem) is required
    # lazily; without it the provider simply reports unavailable and hcolumns'
    # zero-runtime-deps core is untouched.
    class Beads
      MAX_BEADS = 200        # index bound, closed issues rank last
      PROSE_SCAN = 10_000    # chars of description/design/notes scanned for paths
      KNOWN_SCHEMA = 49      # the bd schema_migrations version this provider was written against

      # relation-type mapping for well-known dependency kinds; anything unknown
      # falls back to the upcased type so custom kinds still walk.
      DEP_EDGES = {
        "parent-child" => { from_dependent: :CHILD_OF, from_dependency: :HAS_CHILD },
        "blocks" => { from_dependent: :BLOCKED_BY, from_dependency: :BLOCKS }
      }.freeze

      # A bead's lifecycle status as a glyph, carried in its display name so every
      # renderer (TUI, web, facet) shows the plan's shape at a glance — the same
      # vocabulary `bd list` uses. Unknown statuses fall back to the open glyph.
      STATUS_GLYPH = {
        "open" => "○", "in_progress" => "◐", "blocked" => "●",
        "closed" => "✓", "deferred" => "❄"
      }.freeze

      class << self
        # The pure-Ruby MySQL client, loaded on first use. Absent gem = provider
        # unavailable, nothing else in hcolumns notices.
        def available?
          return @available unless @available.nil?

          @available =
            begin
              require "mysql"
              true
            rescue LoadError
              false
            end
        end

        # The project root owning a `.beads` database, walking up from `path`
        # (the same cheap upward walk as Git.in_repo? — no I/O beyond stat).
        def root_for(path)
          dir = File.expand_path(File.directory?(path) ? path : File.dirname(path))
          loop do
            return dir if File.directory?(File.join(dir, ".beads"))

            parent = File.dirname(dir)
            return nil if parent == dir

            dir = parent
          end
        end

        # Endpoint resolution from repo state — the lesson of the orphaned-DB
        # incident: never assume a port serves this repo. Shared-server mode
        # (config.yaml `dolt.shared-server: true`) reads the shared port file;
        # otherwise the repo's own. Database name comes from metadata.json.
        def endpoint(root)
          beads = File.join(root, ".beads")
          meta = read_json(File.join(beads, "metadata.json"))
          database = meta["dolt_database"] || meta["database"]
          return nil unless database

          port_file = shared_server?(beads) ? File.join(shared_dir, "dolt-server.port") : File.join(beads, "dolt-server.port")
          port = read_port(port_file) || (shared_server?(beads) ? 3308 : 3307)
          { host: "127.0.0.1", user: "root", port: port, database: database }
        end

        # One live client per beads root, shared between the provider and the
        # `bead` content facet (both read the same connection).
        def client_for(root)
          clients.fetch(root) { clients[root] = connect(root) }
        end

        # nil deletes the entry (not caches it), so the next client_for can
        # re-resolve the endpoint — a bounced server heals on the next walk.
        def attach_client(root, client)
          client.nil? ? clients.delete(root) : clients[root] = client
        end

        def reset_clients!
          @clients = {}
        end

        # The bead's long-form fields, for the `bead` facet. nil when unreachable.
        def body(root, id)
          client_for(root)&.body(id)
        end

        def bead_node(root, row)
          name = "#{status_glyph(row[:status])} #{row[:id]} #{row[:title]}".strip
          Node.new(type: :Bead, identity: { scheme: "bead", key: row[:id] },
                   properties: { name: name, bead_id: row[:id],
                                 title: row[:title], status: row[:status], priority: row[:priority],
                                 issue_type: row[:issue_type], beads_root: root })
        end

        def status_glyph(status)
          STATUS_GLYPH.fetch(status, "○")
        end

        # Read the DB's schema_migrations version once per connection and warn if
        # it's newer than what this provider was written against — the lesson of
        # the depends_on_id -> depends_on_issue_id rename: a DB written by a newer
        # bd can present columns we don't map. A missing table means pre-1.x bd
        # (no schema_migrations before v49), which we read on a best-effort basis.
        def guard_schema(client)
          version = client.schema_version
          return if version.nil? || version <= KNOWN_SCHEMA

          warn "beads: schema v#{version} is newer than the v#{KNOWN_SCHEMA} this provider " \
               "expects; some issue columns may be unmapped (update hcolumns' beads provider)"
        end

        def index_node(root, database)
          Node.new(type: :Beads, identity: { scheme: "beads.index", key: root },
                   properties: { name: "beads (#{database})", beads_root: root, database: database })
        end

        private

        def clients
          @clients ||= {}
        end

        def connect(root)
          return nil unless available?

          ep = endpoint(root)
          return nil unless ep

          client = Client.connect(ep)
          guard_schema(client) if client
          client
        end

        def shared_server?(beads_dir)
          config = File.join(beads_dir, "config.yaml")
          File.file?(config) && File.read(config).match?(/^\s*dolt\.shared-server:\s*true\b/)
        end

        def shared_dir
          File.expand_path("~/.beads/shared-server")
        end

        def read_json(path)
          File.file?(path) ? JSON.parse(File.read(path)) : {}
        rescue JSON::ParserError
          {}
        end

        def read_port(path)
          return nil unless File.file?(path)

          port = File.read(path).strip.to_i
          port.positive? ? port : nil
        end
      end

      def initialize(root, client: nil)
        @root = root
        self.class.attach_client(root, client) if client
      end

      def recognizes?(node)
        case node.identity[:scheme]
        when "fs.path" then beads_root_dir?(node) || beads_file?(node)
        when "beads.index", "bead" then node.properties[:beads_root] == @root
        else false
        end
      end

      def expand(node, graph, now:)
        return unless (client = self.class.client_for(@root))

        case node.identity[:scheme]
        when "fs.path"
          if beads_root_dir?(node)
            expand_root(node, graph, now: now, client: client)
          else
            expand_reverse(node, graph, now: now, client: client)
          end
        when "beads.index" then expand_index(node, graph, now: now, client: client)
        when "bead" then expand_bead(node, graph, now: now, client: client)
        end
      rescue StandardError => e
        # A dead server mid-walk shouldn't crash the cascade; drop the client so
        # the next expansion re-resolves the endpoint (the server may be back).
        warn "beads: #{e.message}"
        self.class.attach_client(@root, nil)
      end

      private

      def beads_root_dir?(node)
        path = Filesystem.path_of(node)
        path && File.directory?(path) && File.expand_path(path) == @root
      end

      # A real file under the beads root — the reverse-walk entrypoint. Cheap:
      # a stat, no DB. The reverse index (built lazily on first file expansion)
      # decides which files actually carry edges; here we just gate the tracker.
      def beads_file?(node)
        path = Filesystem.path_of(node)
        path && File.file?(path) && File.expand_path(path).start_with?("#{@root}/")
      end

      def expand_root(node, graph, now:, client:)
        database = self.class.endpoint(@root)&.fetch(:database)
        index = graph.add_node(self.class.index_node(@root, database))
        observe(graph, node, index, :HAS_BEADS, at: now, summary: "issue tracker (#{database})")
      end

      def expand_index(node, graph, now:, client:)
        client.index(limit: MAX_BEADS).each do |row|
          bead = graph.add_node(self.class.bead_node(@root, row))
          observe(graph, node, bead, :HAS_BEAD, at: row[:updated_at] || now,
                                                summary: "P#{row[:priority]} #{row[:issue_type]} · #{row[:status]}")
        end
        # The DB's own ready/blocked views, as overlay edges beside HAS_BEAD —
        # "what can I start now" and "what's waiting", the planner's first question.
        index_view(node, graph, client.ready(limit: MAX_BEADS), :HAS_READY, now: now, note: "ready — no active blocker")
        index_view(node, graph, client.blocked(limit: MAX_BEADS), :HAS_BLOCKED, now: now, note: "blocked")
      end

      def index_view(node, graph, rows, type, now:, note:)
        rows.each do |row|
          bead = graph.add_node(self.class.bead_node(@root, row))
          observe(graph, node, bead, type, at: row[:updated_at] || now,
                                           summary: "#{note} · P#{row[:priority]} #{row[:status]}")
        end
      end

      def expand_bead(node, graph, now:, client:)
        id = node.properties[:bead_id]
        expand_deps(node, graph, id, now: now, client: client)
        expand_files(node, graph, id, now: now, client: client)
      end

      # The dependencies table, both directions from this bead. Rows are
      # (dependent issue_id) -> (dependency depends_on_id): a child depends on
      # its parent, a blocked issue on its blocker.
      def expand_deps(node, graph, id, now:, client:)
        deps = client.deps_for(id)
        others = client.issues_by_ids((deps.flat_map { |d| [d[:issue_id], d[:depends_on_id]] } - [id]).uniq)
                       .to_h { |row| [row[:id], row] }
        deps.each do |dep|
          dependent = dep[:issue_id] == id
          other = others[dependent ? dep[:depends_on_id] : dep[:issue_id]]
          next unless other

          target = graph.add_node(self.class.bead_node(@root, other))
          type = edge_type(dep[:type], dependent: dependent)
          observe(graph, node, target, type, at: now, summary: "#{dep[:type]} · #{other[:status]}")
        end
      end

      def edge_type(dep_type, dependent:)
        mapped = DEP_EDGES[dep_type]
        return mapped[dependent ? :from_dependent : :from_dependency] if mapped

        dep_type.tr("-", "_").upcase.to_sym
      end

      # File links: an explicit list in `metadata` is the agent's word (:agent);
      # a path found in prose is our guess (:inference). Only files that exist
      # under the root become edges — they land on real fs.path nodes, so the
      # walk continues into the full code graph (source/blame/git).
      def expand_files(node, graph, id, now:, client:)
        body = client.body(id) or return
        listed = metadata_files(body[:metadata])
        listed.each do |rel, abs|
          target = graph.add_node(Filesystem.node_for(abs))
          observe(graph, node, target, :TOUCHES, kind: :agent, at: now, summary: "listed in metadata (#{rel})")
        end
        prose_paths(body, exclude: listed.map(&:first)).each do |rel, abs|
          target = graph.add_node(Filesystem.node_for(abs))
          observe(graph, node, target, :TOUCHES, kind: :inference, at: now, summary: "mentioned in text (#{rel})")
        end
      end

      def metadata_files(metadata)
        parsed = metadata.is_a?(String) ? JSON.parse(metadata) : (metadata || {})
        list = %w[files paths touched].flat_map { |key| Array(parsed[key]) }.grep(String)
        resolve_existing(list)
      rescue JSON::ParserError
        []
      end

      def prose_paths(body, exclude:)
        text = [body[:description], body[:design], body[:notes]].join("\n")[0, PROSE_SCAN]
        candidates = text.scan(%r{[\w.-]+(?:/[\w.-]+)+}).uniq - exclude
        resolve_existing(candidates)
      end

      # The reverse walk: from a source file, the beads that touch it. Beads don't
      # index files, so we invert the same metadata/prose scan the forward TOUCHES
      # uses — one bulk query over every bead, parsed into a path -> [bead] map
      # cached for the Workspace (the ruby-const-index pattern). A file with no
      # bead references just adds no edges. TOUCHED_BY mirrors TOUCHES, carrying
      # the same honesty split: :agent for a metadata list, :inference for prose.
      def expand_reverse(file_node, graph, now:, client:)
        abs = File.expand_path(Filesystem.path_of(file_node))
        reverse_index(client).fetch(abs, []).each do |ref|
          bead = graph.add_node(self.class.bead_node(@root, ref[:row]))
          where = ref[:kind] == :agent ? "listed in metadata" : "mentioned in text"
          observe(graph, file_node, bead, :TOUCHED_BY, kind: ref[:kind], at: now,
                                                       summary: "#{where} of #{ref[:row][:id]}")
        end
      end

      def reverse_index(client)
        @reverse_index ||= build_reverse_index(client)
      end

      # abs path -> [{row:, kind:}] for every bead that names it. metadata files
      # win :agent; prose paths (minus the metadata-listed ones) are :inference.
      def build_reverse_index(client)
        index = Hash.new { |h, k| h[k] = [] }
        client.reverse_source(limit: MAX_BEADS).each do |row|
          listed = metadata_files(row[:metadata])
          listed.each { |_rel, abs| index[abs] << { row: row, kind: :agent } }
          prose_paths(row, exclude: listed.map(&:first)).each { |_rel, abs| index[abs] << { row: row, kind: :inference } }
        end
        index
      end

      # [rel, abs] pairs for candidates that are real files under the root.
      def resolve_existing(rels)
        rels.filter_map do |rel|
          abs = File.expand_path(rel, @root)
          [rel, abs] if abs.start_with?("#{@root}/") && File.file?(abs)
        end
      end

      # Dependency rows and index entries are declared facts in the database ->
      # deterministic :structure unless the caller says otherwise.
      def observe(graph, subject, target, type, at:, summary:, kind: :structure)
        graph.observe(Observation.new(
                        provider: :beads, subject_id: subject.id, target_id: target.id, edge_type: type,
                        weight: 1.0, evidence_kind: kind, observed_at: at, evidence_summary: summary
                      ))
      end

      # The MySQL-wire client — the only thing that talks SQL. Everything above
      # speaks in row hashes, so a spec's fake client is a plain object with the
      # same four methods and no server.
      class Client
        INDEX_SQL = "SELECT id, title, status, priority, issue_type, updated_at FROM issues " \
                    "ORDER BY (status = 'closed'), priority, id LIMIT ?"
        # bd computes ready ("no active blocker") and blocked itself, as SQL views.
        # We read the DB's own answer rather than re-deriving the dependency math.
        READY_SQL = "SELECT id, title, status, priority, issue_type, updated_at FROM ready_issues " \
                    "ORDER BY priority, id LIMIT ?"
        BLOCKED_SQL = "SELECT id, title, status, priority, issue_type, updated_at FROM blocked_issues " \
                      "ORDER BY priority, id LIMIT ?"
        ISSUE_COLS = "id, title, status, priority, issue_type"
        BODY_SQL = "SELECT id, title, status, priority, issue_type, assignee, description, design, " \
                   "acceptance_criteria, notes, metadata, created_at, updated_at FROM issues WHERE id = ?"
        # Enough of each issue to both build its node and scan it for file paths,
        # in one round-trip — the backing query for the reverse (file -> bead) walk.
        REVERSE_SQL = "SELECT id, title, status, priority, issue_type, description, design, notes, metadata " \
                      "FROM issues LIMIT ?"

        def self.connect(endpoint)
          conn = Mysql.connect(endpoint[:host], endpoint[:user], nil, endpoint[:database], endpoint[:port])
          new(conn)
        rescue StandardError
          nil
        end

        def initialize(conn)
          @conn = conn
        end

        def index(limit:)
          rows(INDEX_SQL, limit).map { |r| index_row(r) }
        end

        def ready(limit:) = view_rows(READY_SQL, limit)
        def blocked(limit:) = view_rows(BLOCKED_SQL, limit)

        def deps_for(id)
          rows("SELECT issue_id, depends_on_issue_id, type FROM dependencies " \
               "WHERE issue_id = ? OR depends_on_issue_id = ?", id, id)
            .map { |r| { issue_id: r[0], depends_on_id: r[1], type: r[2] } }
        end

        def issues_by_ids(ids)
          return [] if ids.empty?

          marks = (["?"] * ids.size).join(", ")
          rows("SELECT #{ISSUE_COLS}, updated_at FROM issues WHERE id IN (#{marks})", *ids).map { |r| index_row(r) }
        end

        def body(id)
          r = rows(BODY_SQL, id).first or return nil
          { id: r[0], title: r[1], status: r[2], priority: r[3], issue_type: r[4], assignee: r[5],
            description: r[6], design: r[7], acceptance_criteria: r[8], notes: r[9], metadata: r[10],
            created_at: r[11], updated_at: r[12] }
        end

        def reverse_source(limit:)
          rows(REVERSE_SQL, limit).map do |r|
            { id: r[0], title: r[1], status: r[2], priority: r[3], issue_type: r[4],
              description: r[5], design: r[6], notes: r[7], metadata: r[8] }
          end
        end

        # The bd schema version (schema_migrations, v49+). nil when the table is
        # absent (pre-1.x bd) — the guard treats that as read-on-best-effort.
        def schema_version
          rows("SELECT MAX(version) FROM schema_migrations").first&.first
        rescue StandardError
          nil
        end

        private

        def index_row(r)
          { id: r[0], title: r[1], status: r[2], priority: r[3], issue_type: r[4], updated_at: r[5] }
        end

        # The ready/blocked views ship with bd >= 1.x; on an older DB they're
        # simply absent, so a query error just omits the overlay (the schema
        # guard is what signals a version mismatch — this stays quiet).
        def view_rows(sql, limit)
          rows(sql, limit).map { |r| index_row(r) }
        rescue StandardError
          []
        end

        def rows(sql, *params)
          @conn.prepare(sql).execute(*params).to_a
        end
      end
    end
  end
end
