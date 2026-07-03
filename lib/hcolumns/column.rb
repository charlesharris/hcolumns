# frozen_string_literal: true

module HColumns
  # One ranked candidate in a column: a relation from the selected node to a
  # target, carrying its derived confidence/recency/maturity, its score, and the
  # provenance behind it.
  class ColumnEntry
    attr_reader :edge, :target, :score, :confidence, :recency, :maturity, :flag

    def initialize(edge:, target:, now:, lens:, flag: nil)
      @edge = edge
      @target = target
      @flag = flag # the user's up/down judgment on the target, if any
      @score = lens.score(edge, now: now) * lens.bias(flag && flag[:level])
      @confidence = lens.confidence(edge, now: now) # untouched by flags: evidence, not opinion
      @recency = edge.recency(now: now)
      @maturity = edge.maturity(now: now) # structural truth, unaffected by the lens
    end

    def relation
      edge.type
    end

    def provenance
      edge.observations
    end

    # A one-line explanation of why this entry ranks where it does.
    def rank_reason
      kinds = edge.evidence_kinds.map(&:to_s).join("+")
      summary = edge.observations.map(&:evidence_summary).compact.first
      base = summary || "#{edge.observations.size} observation(s)"
      "#{base} [#{kinds}]; conf #{format('%.2f', confidence)}#{flag_note}"
    end

    # The visible trace of a bias — so a reordered column never looks like the
    # evidence changed. "⚑down (charris)" beside an untouched confidence bar.
    def flag_note
      return "" unless flag

      by = flag[:by] ? " (#{flag[:by]})" : ""
      " · ⚑#{flag[:level]}#{by}"
    end
  end

  # Entries sharing a relation type, ranked within the group.
  class ColumnGroup
    attr_reader :relation, :entries

    def initialize(relation:, entries:)
      @relation = relation
      @entries = entries
    end

    def top_score
      entries.first&.score || 0.0
    end
  end

  # A built column: the relation-grouped, ranked expansion of one node — what the
  # UI renders, and the unit a selection pushes onto the cascade.
  class Column
    attr_reader :root, :groups

    def initialize(root:, groups:)
      @root = root
      @groups = groups
    end

    def entries
      groups.flat_map(&:entries)
    end

    def empty?
      groups.empty?
    end
  end
end
