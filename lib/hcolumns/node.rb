# frozen_string_literal: true

module HColumns
  # A node in the property graph — anything the system can recognize, preview,
  # relate, or act on (a file, a span, a log line, a commit, a person, ...).
  class Node
    attr_reader :id, :type, :labels, :properties, :identity

    def initialize(type:, identity:, labels: [], properties: {}, id: nil)
      @identity = identity
      @id = id || Identity.id_for(**identity)
      @type = type.to_sym
      @labels = labels
      @properties = properties
    end

    def name
      properties[:name] || properties[:path] || id
    end

    def to_s
      name.to_s
    end
  end
end
