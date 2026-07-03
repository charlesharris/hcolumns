# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rspec", "~> 3.13"
  # Soft runtime dependency: the beads provider needs a MySQL-wire client to
  # read the dolt database; without it the provider reports unavailable and
  # the rest of hcolumns stays zero-dep. Pure Ruby, in keeping with no-native.
  gem "ruby-mysql", "~> 4.2"
  gem "bigdecimal" # ruby-mysql needs it but doesn't declare it (gone from Ruby 3.4 defaults)
end
