# frozen_string_literal: true

require "fileutils"
require "hcolumns"

# A pinned clock for deterministic decay/recency/ranking across the suite.
FIXED_NOW = Time.utc(2026, 6, 10, 12, 0, 0)

# Golden-file assertion: compare `actual` to a checked-in expected file.
# Run with UPDATE_GOLDEN=1 to (re)write the expected files.
module GoldenHelper
  GOLDEN_DIR = File.expand_path("fixtures/golden", __dir__)

  def golden(name, actual)
    path = File.join(GOLDEN_DIR, name)
    if ENV["UPDATE_GOLDEN"]
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, actual)
    end
    raise "missing golden #{name}; run UPDATE_GOLDEN=1 to create it" unless File.exist?(path)

    expect(actual).to eq(File.read(path))
  end
end

RSpec.configure do |config|
  config.include GoldenHelper
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :defined
end
