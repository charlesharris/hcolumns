# frozen_string_literal: true

module HColumns
  # A named way of looking at the same graph. A lens composes three re-weightings
  # plus an optional scope:
  #
  #   tuner             evidence math — confidence floor + per-evidence-kind mix
  #   relation_weights  per-relation-family emphasis on the score (dim/lift a
  #                     whole family, e.g. a "git" lens lifts commits, dims files)
  #   scope             the opt-in escalation: hide families outright (only:/hide:)
  #
  # This base class is the *engine* (how a lens scores, filters, and retunes) and
  # also serves as the neutral `:default` lens. Each concrete lens lives in its own
  # file under `lenses/` as a subclass that overrides the declarative class-level
  # config below — so adding a lens is "drop a file, register it", with no change
  # here. Lenses are looked up and cycled through a name -> class registry.
  #
  # The split is deliberate: re-weighting (tuner + relation_weights) re-orders but
  # never hides; scoping is the stronger, opt-in move. A lens with no scope keeps
  # the "re-weight, never toggle" posture; one that sets only:/hide: chooses to
  # filter. See docs/DESIGN.md and the tuner.
  class Lens
    attr_reader :name, :tuner, :scope, :relation_weights

    def initialize(name: self.class.default_name, tuner: self.class.default_tuner,
                   scope: self.class.default_scope, relation_weights: self.class.default_relation_weights)
      @name = name.to_sym
      @tuner = tuner
      @scope = scope
      @relation_weights = relation_weights
    end

    # Declarative config — concrete lenses override these (and nothing else, in
    # the common case). The base values are the neutral default lens.
    def self.default_name = :default
    def self.default_tuner = Tuner.new
    def self.default_scope = nil
    def self.default_relation_weights = {}

    # The score a column ranks by: the tuner's evidence score, biased by this
    # lens's emphasis on the relation family (default 1.0 — no change).
    def score(edge, now:)
      tuner.score(edge, now: now) * relation_weights.fetch(edge.type, 1.0)
    end

    # A user flag's score multiplier. The level -> number mapping lives HERE, in
    # the opinion layer, because a flag biases *ranking* only: confidence still
    # reports the untouched evidence (a lens could even weigh flags differently).
    # :exclude never reaches scoring — the builder hides those entries outright.
    FLAG_BIAS = { up: 1.5, down: 0.4 }.freeze

    def bias(flag_level)
      flag_level ? FLAG_BIAS.fetch(flag_level, 1.0) : 1.0
    end

    # Confidence and the floor are pure evidence (the tuner); the lens delegates.
    def confidence(edge, now:)
      tuner.confidence(edge, now: now)
    end

    def visible?(edge, now:)
      tuner.visible?(edge, now: now)
    end

    # Is this relation family in view under the scope? No scope admits all.
    def admits?(relation)
      return true unless scope
      return scope[:only].include?(relation) if scope[:only]
      return !scope[:hide].include?(relation) if scope[:hide]

      true
    end

    # A copy (same lens type) with the confidence floor overridden — the live
    # `[`/`]` retune. Keeps the lens's mix, scope, and relation emphasis.
    def with_floor(floor)
      self.class.new(
        name: name,
        tuner: Tuner.new(tuner.weights.merge(floor: floor), evidence_mix: tuner.evidence_mix),
        scope: scope,
        relation_weights: relation_weights
      )
    end

    # --- registry: name -> lens class, in registration (== cycle) order --------

    @registry = {}

    class << self
      attr_reader :registry

      # Concrete lenses call this at the bottom of their file.
      def register(klass)
        registry[klass.default_name] = klass
      end

      def preset(name)
        klass = registry.fetch(name.to_sym) do
          raise ArgumentError, "unknown lens preset: #{name.inspect}"
        end
        klass.new
      end

      def names
        registry.keys
      end

      # The next lens after `current`, wrapping around — drives the `r` cycle.
      def cycle(current)
        keys = registry.keys
        i = keys.index(current.to_sym) || -1
        preset(keys[(i + 1) % keys.length])
      end
    end

    register(self) # the base class is the neutral :default lens
  end
end
