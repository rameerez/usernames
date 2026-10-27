# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in usernames.gemspec
gemspec

gem "rake", "~> 13.0"

group :test do
  gem "appraisal"
  gem "minitest", "~> 6.0"
  gem "minitest-mock"
  gem "minitest-reporters", "~> 1.6"
  gem "sqlite3", "~> 2.1"
  # The PostgreSQL leg of the suite (DATABASE_URL=postgres://…): collations and
  # unique-violation diagnostics are where SQLite and PostgreSQL disagree.
  gem "pg"
  gem "simplecov", require: false
  # Reads test/fixtures/username_table.csv; a bundled (not default) gem since Ruby 3.4.
  gem "csv"
  gem "rubocop", require: false
  gem "rubocop-minitest", require: false
  gem "rubocop-performance", require: false
end
