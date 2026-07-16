# frozen_string_literal: true

require "fileutils"
require "securerandom"

module HColumns
  # Fire an LLM request from hcolumns and get the answer back as a node (hc-4s4).
  #
  # This is the consumer `hcol fix` was already writing requests for. That verb
  # appends a FixRequest and STOPS, deliberately — the log is replayed on every
  # walk, so a request that *fired* on replay would re-run a fix weeks later from
  # a snapshot with nobody watching. Dispatch therefore belongs to a consumer that
  # tracks its own cursor. This is that consumer.
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
    Task = Struct.new(:key, :prompt, :handle, :state, keyword_init: true)

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
    def submit(prompt, key: nil)
      key ||= SecureRandom.hex(4)
      task = Task.new(key: key, prompt: prompt, state: :pending)
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
      @bridge.apply("task #{task.key} #{state} #{text.to_s.gsub(/\s+/, ' ')}")
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
