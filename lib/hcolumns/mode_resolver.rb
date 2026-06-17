# frozen_string_literal: true

module HColumns
  # Picks the modes (tabs) for a node *in context*. The head of the returned list
  # is the auto mode — the default a column opens on; the rest are the alternative
  # tabs, resolver-ranked rather than "every lens always". This is the keystone of
  # the dynamic interface: the lens stops being one global toggle and becomes a
  # function of where you are.
  #
  # Today the policy is keyed on node type only. The `session:` argument is the
  # seam for the next slice: a goal/phase the agent emits will reorder this list
  # live (float `debug` to the head while debugging, etc.) — same abstraction,
  # the head just stops being static.
  class ModeResolver
    # node type -> ordered mode keys (first = auto). `:details` rides along on
    # everything so the inspector is always a tab away.
    POLICY = {
      SourceFile: %i[default git details],
      TestFile: %i[reviewer default details],
      Directory: %i[default git details],
      ProposedChange: %i[reviewer git details],
      TestRun: %i[default details],
      LogLine: %i[default details],
      Session: %i[default details],
      Sessions: %i[default details],
      Person: %i[git details],
      Agent: %i[default details]
    }.freeze

    DEFAULT = %i[default details].freeze

    def modes_for(node, session: nil)
      keys(node, session).map { |key| Mode[key] }
    end

    # The auto mode — the head of the ranked list.
    def auto(node, session: nil)
      modes_for(node, session: session).first
    end

    private

    def keys(node, _session)
      POLICY.fetch(node.type, DEFAULT)
    end
  end
end
