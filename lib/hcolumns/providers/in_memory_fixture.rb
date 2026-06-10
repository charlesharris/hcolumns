# frozen_string_literal: true

module HColumns
  module Providers
    # A hand-authored coding-workspace graph: the golden-test substrate and the
    # CLI demo. Observation timestamps are authored *relative to `now`* so decay
    # is meaningful and the demo looks sensible, while tests that pin `now` stay
    # deterministic. It stands in for what real providers (filesystem, git,
    # naming-rules, markdown, a human) would append.
    module InMemoryFixture
      module_function

      ORDERS_KEY = { scheme: "fs.path", key: "local:/repo/src/orders.rb" }.freeze

      def orders_id
        Identity.id_for(**ORDERS_KEY)
      end

      def build(now:)
        graph = Graph.new
        days = ->(d) { now - (d * Evidence::DAY_SECONDS) }

        file = lambda do |type, path|
          graph.add_node(Node.new(type: type, identity: { scheme: "fs.path", key: "local:/repo/#{path}" },
                                  properties: { name: path, path: path }))
        end

        repo      = graph.add_node(Node.new(type: :Directory, identity: { scheme: "fs.path", key: "local:/repo" },
                                            properties: { name: "repo/", path: "." }))
        src       = file.(:Directory, "src")
        spec      = file.(:Directory, "spec")
        orders    = file.(:SourceFile, "src/orders.rb")
        payments  = file.(:SourceFile, "src/payments.rb")
        inventory = file.(:SourceFile, "src/inventory.rb")
        orders_t  = file.(:TestFile, "spec/orders_spec.rb")
        readme    = file.(:Doc, "README.md")
        alice     = graph.add_node(Node.new(type: :Person, identity: { scheme: "person", key: "alice" },
                                            properties: { name: "alice" }))

        obs = lambda do |provider, subject, object, type, **kw|
          graph.observe(Observation.new(provider: provider, subject_id: subject.id,
                                        target_id: object.id, edge_type: type, **kw))
        end

        # structure — containment (deterministic, does not decay)
        [[repo, src], [repo, spec], [repo, readme],
         [src, orders], [src, payments], [src, inventory], [spec, orders_t]].each do |s, o|
          obs.(:filesystem, s, o, :CONTAINS, weight: 1.0, evidence_kind: :structure,
               observed_at: days.(0), evidence_summary: "directory entry")
        end

        # structure — naming-rule source<->test pair (crisp)
        obs.(:naming, orders, orders_t, :PAIR, weight: 1.0, evidence_kind: :structure,
             observed_at: days.(0), evidence_summary: "name matches spec/orders_spec.rb")

        # human — someone confirmed the pair (lifts it to 'confirmed')
        obs.(:user, orders, orders_t, :PAIR, weight: 1.0, evidence_kind: :human,
             observed_at: days.(3), evidence_summary: "confirmed by charris")

        # history — git co-change (decays over ~90d)
        obs.(:git, orders, payments, :CO_CHANGED_WITH, weight: 0.9, evidence_kind: :history,
             observed_at: days.(2), evidence_summary: "changed together in 14 of 90 days")
        obs.(:git, orders, inventory, :CO_CHANGED_WITH, weight: 0.4, evidence_kind: :history,
             observed_at: days.(20), evidence_summary: "changed together in 5 of 90 days")

        # history — authorship
        obs.(:git, orders, alice, :CHANGED_BY, weight: 0.6, evidence_kind: :history,
             observed_at: days.(1), evidence_summary: "37 commits")

        # inference — doc mention (README -> orders; incoming to orders, not in its column)
        obs.(:markdown, readme, orders, :MENTIONS, weight: 0.5, evidence_kind: :inference,
             observed_at: days.(7), evidence_summary: "README §Orders links src/orders.rb")

        graph
      end
    end
  end
end
