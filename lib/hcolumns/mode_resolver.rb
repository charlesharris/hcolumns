# frozen_string_literal: true

module HColumns
  # Picks the modes (tabs) for a node *in context*. The head of the returned list
  # is the auto mode — the default a column opens on; the rest are the alternative
  # tabs, resolver-ranked rather than "every lens always". This is the keystone of
  # the dynamic interface: the lens stops being one global toggle and becomes a
  # function of where you are.
  #
  # The base policy is keyed on node type; a session's *phase* (what the agent is
  # doing) then floats phase-preferred modes to the head, so the auto mode follows
  # the workflow — a SourceFile reads as `default` while editing but flips to
  # `details` while debugging. Phase can only promote a mode the node can actually
  # render (applicability); `:details` is always kept available.
  class ModeResolver
    # node type -> ordered mode keys (first = auto, absent a phase).
    POLICY = {
      SourceFile: %i[default source blame git details],
      TestFile: %i[reviewer default source blame details],
      Doc: %i[default source blame details],
      File: %i[default source blame details],
      # A directory's tabs are the stratum switcher: the same node re-lensed
      # per world (files / git / plan / session), each lifting its stratum's
      # sections to the top and dimming the rest — never hiding.
      Directory: %i[default filesystem git beads session details],
      Commit: %i[gitdiff default details],
      CommitFile: %i[gitdiff commitsource details], # diff-first (blame arrival asks "what changed"), source a tab away
      ProposedChange: %i[diff reviewer details],
      TestRun: %i[output default details],
      LogLine: %i[output default details],
      Session: %i[default turns details],
      Sessions: %i[default details],
      Bead: %i[default bead details],
      Beads: %i[default details],
      Person: %i[git details],
      Agent: %i[default details]
    }.freeze

    DEFAULT = %i[default details].freeze

    # phase -> mode keys to float to the head (in this order) when they apply.
    PHASE_PREFERENCE = {
      exploring: %i[explorer git],
      editing: %i[diff default],
      testing: %i[reviewer details],
      debugging: %i[details git],
      reviewing: %i[reviewer diff details]
    }.freeze

    def modes_for(node, session: nil)
      modes = ordered_keys(node, session&.phase).map { |key| Mode[key] }.select { |mode| mode.applies?(node) }
      ensure_details(modes)
    end

    # The auto mode — the head of the ranked list (shifts with the phase).
    def auto(node, session: nil)
      modes_for(node, session: session).first
    end

    private

    def ordered_keys(node, phase)
      base = POLICY.fetch(node.type, DEFAULT)
      return base unless phase

      (PHASE_PREFERENCE.fetch(phase, []) + base).uniq # phase-preferred first, then the type defaults
    end

    def ensure_details(modes)
      modes.any? { |m| m.name == :details } ? modes : modes + [Mode[:details]]
    end
  end
end
