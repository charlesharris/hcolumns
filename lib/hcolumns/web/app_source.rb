# frozen_string_literal: true

module HColumns
  module Web
    # The concurrency seam between the Server and its App(s). The Server never
    # holds an App directly — it asks its AppSource to `checkout` one per
    # connection and calls plain App methods on what it gets back. That keeps
    # the concurrency *strategy* a constructor-time choice:
    #
    #   Single        one shared App, no locking — for the single-threaded
    #                 (non-streaming) server, where requests are serial anyway.
    #   PerConnection a fresh App per checkout (share-nothing) — each connection
    #                 projects its own graph from the shared read-only sources
    #                 (the log tail, the lazily-indexed filesystem), so a
    #                 long-lived /events stream beside /panel fetches needs no
    #                 lock. The cost is duplicate indexing per connection.
    #
    #   Locked        one shared App behind a mutex — every checkout returns the
    #                 same synchronizing decorator, so concurrent connections
    #                 serialize on one warm graph. This is the only strategy
    #                 that can serve lazily-expanded *pull* strata (filesystem/
    #                 git/beads) under a threaded server: expansion accretes in
    #                 the one graph, and a node id minted by one request's
    #                 descent (an identity digest — not resolvable on its own)
    #                 stays findable by the next.
    module AppSource
      class Single
        def initialize(app)
          @app = app
        end

        def checkout
          @app
        end
      end

      class PerConnection
        def initialize(build)
          @build = build
        end

        def checkout
          @build.call
        end
      end

      class Locked
        # The decorator holds the mutex per CALL, never across a caller's loop —
        # a long-lived /events stream locks only for each pump/version peek, so
        # panel fetches interleave with it instead of starving behind it.
        class LockedApp
          APP_API = %i[pump version done? panel root flag live? root_id].freeze

          def initialize(app, mutex)
            @app = app
            @mutex = mutex
          end

          APP_API.each do |method|
            define_method(method) do |*args, **kwargs|
              @mutex.synchronize { @app.public_send(method, *args, **kwargs) }
            end
          end
        end

        def initialize(app)
          @locked = LockedApp.new(app, Mutex.new)
        end

        def checkout
          @locked
        end
      end
    end
  end
end
