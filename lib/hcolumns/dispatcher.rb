# frozen_string_literal: true

module HColumns
  # Queue work from a front-end (hc-4s4, the UI-dispatch hop). The web echo of
  # `hcol ask`/`hcol fix`: it turns a click into a Request event on the bridge log —
  # the same log the serve is tailing — so the intent appears in the columns live and
  # a runner (`hcol run`, or the execute path) can pick it up.
  #
  # It QUEUES only. Queuing is as safe as `hcol ask` — a Request is a stated intent,
  # nothing runs until something dispatches it — so it needs no permission story and
  # is always available. EXECUTION (spawning an agent that edits code from a browser
  # click) is the separate, opt-in half that carries the worktree-isolation safety
  # story; it is not this object's job.
  #
  # No HTTP in here, exactly like Web::App has none: it takes a log path and speaks
  # the neutral bridge vocabulary, so the same object could back a TUI action or a
  # different front-end without change.
  class Dispatcher
    def initialize(log:, session: "live", clock: -> { Time.now })
      @bridge = AgentBridge.new(path: log, session: session, clock: clock)
    end

    # Queue a Suggestion's fix as a Request (the web echo of `hcol fix`). The Request
    # points back at the suggestion by id, so the suggestion's incoming edges show it
    # was asked about. Returns a receipt, or nil when the node isn't a suggestion or
    # carries no fix — reported for honesty, not action, so there's nothing to hand off.
    def dispatch_suggestion(node)
      return nil unless node&.type == :Suggestion

      prompt = node.properties[:fix]
      return nil if prompt.to_s.strip.empty?

      @bridge.apply("request fix #{node.id} #{squish(prompt)}")
      { ok: true, queued: "fix", id: node.id, prompt: squish(prompt) }
    end

    # Queue an arbitrary prompt (the web echo of `hcol ask`). Returns nil for an
    # empty prompt so the router can reject it.
    def ask(prompt)
      text = squish(prompt)
      return nil if text.empty?

      @bridge.apply("request ask - #{text}")
      { ok: true, queued: "ask", prompt: text }
    end

    private

    def squish(str)
      str.to_s.gsub(/\s+/, " ").strip
    end
  end
end
