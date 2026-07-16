# frozen_string_literal: true

require_relative "lib/hcolumns/version"

Gem::Specification.new do |spec|
  spec.name = "hcolumns"
  spec.version = HColumns::VERSION
  spec.authors = ["Charles Harris"]
  spec.email = ["charris000@gmail.com"]

  spec.summary = "Semantically-directed Miller columns (Harris Columns)"
  spec.description = "A structured, directed way to explore a property graph as " \
                    "ranked, relation-grouped, walkable columns. A playground for " \
                    "the harris-columns idea."
  spec.homepage = "https://github.com/charlesharris/hcolumns"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  # Prose only: the README's screenshots live under docs/images/ and have no
  # business in the installed gem.
  spec.files = Dir["lib/**/*.rb", "exe/*", "docs/**/*.md", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["hcol"]
  spec.require_paths = ["lib"]
end
