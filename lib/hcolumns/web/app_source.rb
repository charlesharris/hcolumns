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
          APP_API = %i[pump version done? panel root flag dispatch dispatch_available? ask
                       execution_available? retry_task review live? root_id].freeze

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

      # Locked, plus re-projection: the graph is a projection of the world, so
      # when the world moves, rebuild it rather than patch it. `probe` returns a
      # cheap fingerprint of the pull sources (git HEAD, beads storage, …); when
      # it changes, `pump` swaps in a freshly built App under the lock. The swap
      # is safe by construction — everything user-visible replays (flags from
      # their store, the session from its log, pull strata re-derive lazily).
      # `version` carries a generation term so a swap bumps it even though the
      # re-folded log reports the same count — that's what makes SSE clients
      # re-fetch their open columns against the fresh graph.
      class Refreshing
        class SwappingApp
          DELEGATED = %i[done? panel root flag dispatch dispatch_available? ask
                         execution_available? retry_task review live? root_id].freeze

          def initialize(build, probe, interval, mutex)
            @build = build
            @probe = probe
            @interval = interval
            @mutex = mutex
            @app = build.call
            @fingerprint = probe.call
            @generation = 0
            @probed_at = monotime
          end

          # The one hook point: every serving path pumps a live app before it
          # answers, so "release due events" is also where the world gets a
          # (throttled) second look.
          def pump
            @mutex.synchronize do
              reproject_if_moved
              @app.pump
            end
          end

          def version
            @mutex.synchronize { @app.version + @generation }
          end

          DELEGATED.each do |method|
            define_method(method) do |*args, **kwargs|
              @mutex.synchronize { @app.public_send(method, *args, **kwargs) }
            end
          end

          private

          def reproject_if_moved
            return if monotime - @probed_at < @interval

            @probed_at = monotime
            current = @probe.call
            return if current == @fingerprint

            @fingerprint = current
            @app = @build.call
            @generation += 1
          end

          def monotime
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end

        def initialize(build, probe:, interval: 2.0)
          @swapping = SwappingApp.new(build, probe, interval, Mutex.new)
        end

        def checkout
          @swapping
        end
      end
    end
  end
end
