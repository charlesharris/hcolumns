# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "set"

module HColumns
  # Fire an LLM request from hcolumns and get the answer back as a node (hc-4s4).
  #
  # This is the consumer for the log's `request` verb — the only INTENT in the
  # vocabulary. That verb appends a Request and STOPS, deliberately: the log is
  # replayed on every walk, and a request that *fired* on replay would re-run work
  # weeks later from a snapshot with nobody watching. Dispatch belongs out here.
  #
  # It runs a REQUEST, not "a fix" (Charris's call). A fix is just a request whose
  # prompt came from a suggestion — `kind` and `subject` are provenance for a human
  # reading the column, and nothing in this file reads them. That keeps the runner
  # open: `hcol fix`, `hcol ask`, a hook, or a future rule all queue work the same
  # way, and none of them are special to the thing that executes it.
  #
  # It runs OUT OF PROCESS, per the rule layer 17 earned: concurrency lives
  # between processes and the file is the shared state, so nothing here needs a
  # mutex. The runner appends task-state events to the host log; the spawned agent
  # appends its own work to a task-scoped log; they meet only on disk.
  #
  # The strategy seam is the point — "plug-and-play LLMs and interaction
  # strategies". A strategy implements:
  #
  #   start(task)  -> handle   # begin work; return anything opaque
  #   poll(handle) -> :running | { status: :done | :failed, response: String }
  #   stop(handle)             # best-effort teardown
  #
  # Strategies::Echo is the test double, so the runner is fully specifiable with
  # no LLM, no network and no tmux. Strategies::TmuxClaudeCode is the default.
  class LLMTaskRunner
    Task = Struct.new(:key, :prompt, :handle, :state, :request_id, keyword_init: true)

    def initialize(strategy:, log:, session: "live", clock: -> { Time.now })
      @strategy = strategy
      @log = log
      @bridge = AgentBridge.new(path: log, session: session, clock: clock)
      @tasks = {}
    end

    attr_reader :tasks

    # Queue a prompt and start it. Returns the task key — the handle a caller (or
    # a walk) uses to find the node. The node exists BEFORE the work does, in
    # :pending, so the column shows the task the moment it is asked for rather
    # than when it happens to finish.
    def submit(prompt, key: nil, request_id: nil)
      key ||= SecureRandom.hex(4)
      task = Task.new(key: key, prompt: prompt, state: :pending, request_id: request_id)
      @tasks[key] = task
      emit(task, :pending, summary_of(prompt))
      begin
        task.handle = @strategy.start(task)
        transition(task, :running, summary_of(prompt))
      rescue StandardError => e
        transition(task, :failed, "could not start: #{e.message}")
      end
      key
    end

    # Advance every in-flight task one step. Returns how many changed state, so a
    # caller can decide whether anything is worth re-rendering. Never raises: a
    # strategy that blows up fails ITS task, not the runner and not the other
    # tasks in flight.
    def poll
      changed = 0
      running.each do |task|
        result = begin
          @strategy.poll(task.handle)
        rescue StandardError => e
          { status: :failed, response: "strategy error: #{e.message}" }
        end
        next if result == :running

        transition(task, result[:status], result[:response].to_s)
        changed += 1
      end
      changed
    end

    # Every request in `graph` that has no task hanging off it yet — i.e. what is
    # OUTSTANDING, asked of the graph rather than tracked on the side.
    #
    # Generic on purpose (Charris's call): this asks for :Request, not for a fix.
    # A fix is only a request whose prompt came from a suggestion; `kind` and
    # `subject` are provenance for a human reading the column, and dispatch reads
    # neither. Anything that can phrase a prompt can queue work here.
    #
    # It is also what makes replay safe. A replayed log contains the request AND
    # the task it was dispatched as, so nothing looks outstanding and nothing
    # re-fires — the property falls out of the fold instead of needing a cursor
    # file that can drift out of sync with the log it describes.
    def self.outstanding(graph)
      dispatched = graph.nodes.select { |n| n.type == :LLMTask }
                        .filter_map { |n| n.properties[:request_id] }.to_set
      graph.nodes.select { |n| n.type == :Request && !dispatched.include?(n.id) }
    end

    # Reconcile the graph against the world before taking on new work (hc-4s4). A
    # runner dies with its shell — SIGHUP'd when the terminal closes — while the
    # agents it spawned keep working in detached panes and finish on disk with nobody
    # left to read them. Because the log is truth, the answer is not to daemonize but
    # to RECONCILE: re-adopt every task the graph still shows in flight so the normal
    # poll loop settles it (finished→done even if the pane has since closed,
    # dead→failed, still-working→driven to completion), and reap the panes of tasks
    # already terminal. Idempotent — two runners reconciling the same task fold the
    # same latest-wins node — so it stays safe under the multi-process model.
    #
    # A strategy without adopt/reap_orphans (the Echo double) simply has nothing to
    # recover, so this is a no-op there. Returns the count re-adopted, for a caller
    # to report.
    def reconcile(graph)
      return 0 unless @strategy.respond_to?(:adopt)

      llm_tasks = graph.nodes.select { |n| n.type == :LLMTask }
      adopted = llm_tasks.count do |node|
        key = node.properties[:task_key]
        next false if key.nil? || @tasks.key?(key) || %i[done failed].include?(node.properties[:state])

        @tasks[key] = Task.new(key: key, prompt: node.properties[:output]&.first,
                               handle: @strategy.adopt(key), state: :running,
                               request_id: node.properties[:request_id])
        true
      end

      if @strategy.respond_to?(:reap_orphans)
        terminal = llm_tasks.select { |n| %i[done failed].include?(n.properties[:state]) }
                            .filter_map { |n| n.properties[:task_key] }
        @strategy.reap_orphans(terminal) unless terminal.empty?
      end

      adopted
    end

    # Submit every outstanding request. Returns the keys started.
    def submit_outstanding(graph)
      self.class.outstanding(graph).map do |request|
        submit(request.properties[:prompt], request_id: request.id)
      end
    end

    def running = @tasks.values.select { |t| t.state == :running }

    def done? = running.empty?

    # Block until everything settles. `timeout` is the runner's own guard, not the
    # strategy's: an agent that stops to ask an interactive question would
    # otherwise hang here forever — the failure mode the tmux-driving prior art
    # is known for.
    def run_to_completion(timeout: 600, interval: 0.5, sleeper: ->(s) { sleep(s) })
      waited = 0.0
      until done? || waited >= timeout
        poll
        sleeper.call(interval)
        waited += interval
      end
      running.each { |task| transition(task, :failed, "timed out after #{timeout}s") }
      @tasks.values
    end

    private

    def transition(task, state, text)
      task.state = state
      emit(task, state, text)
      @strategy.stop(task.handle) if %i[done failed].include?(state) && task.handle
    end

    # One digest-keyed node re-emitted per state (the TestRun pattern): latest fold
    # wins, so a live walk shows ◌ → ◐ → ✓/✗ flip in place rather than piling up.
    def emit(task, state, text)
      @bridge.apply("task #{task.key} #{state} #{task.request_id || '-'} #{text.to_s.gsub(/\s+/, ' ')}")
    end

    def summary_of(prompt)
      prompt.to_s.strip.gsub(/\s+/, " ")[0, 60]
    end
  end

  module Strategies
    # The test double: answers immediately from a canned table, so the runner's
    # lifecycle, timeout and failure paths are all specifiable with no LLM, no
    # network and no tmux. Every real strategy is measured against this shape.
    class Echo
      def initialize(answers: {}, fail_on: [], never_finish: [])
        @answers = answers
        @fail_on = fail_on
        @never_finish = never_finish
      end

      def start(task)
        raise "echo refused #{task.key}" if @fail_on.include?(task.key)

        task.key
      end

      def poll(handle)
        return :running if @never_finish.include?(handle)

        { status: :done, response: @answers.fetch(handle, "echo: #{handle}") }
      end

      def stop(_handle) = nil
    end
  end
end
