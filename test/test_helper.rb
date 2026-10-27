# frozen_string_literal: true

require "bundler/setup"

# SimpleCov must be loaded BEFORE any application code
# Configuration is auto-loaded from .simplecov file
require "simplecov"
SimpleCov.start

require "minitest/autorun"
require "minitest/mock"
require "minitest/reporters"
Minitest::Reporters.use!(Minitest::Reporters::SpecReporter.new)

require "csv"
require "logger"
require "rails"
require "active_record"
# Action Dispatch for the route tests, and for the Mime registry the
# file-extension rule reads.
require "action_controller"

# Loaded BEFORE the application initializes, as Bundler.require does in a
# real app, so the engine's initializers (locales, Active Record hook,
# configuration check) take part.
require "usernames"

# Define a minimal Rails app for the engine and Active Record
class TestApp < Rails::Application
  config.eager_load = false
  config.logger = Logger.new($stdout)
  config.log_level = :warn
  config.root = File.expand_path("..", __dir__)
  config.active_support.deprecation = :stderr
  config.secret_key_base = "a" * 64

  # The app's own locale files. Not config/locales: with the gem's root as the
  # app's root, that would be the engine's files a second time, and the engine
  # test could not tell "engine first, app last" apart.
  config.paths.add "config/locales", with: "test/fixtures/locales", glob: "**/*.{rb,yml}"
  # Likewise the app's lib/tasks (it has none): the engine's are loaded by
  # the engine, as in a real app.
  config.paths.add "lib/tasks", with: "test/fixtures/tasks", glob: "**/*.rake"

  # Disable asset pipeline for this test app (no assets in gem)
  config.assets = nil if config.respond_to?(:assets=)
end

# Initialize the application
Rails.application.initialize!

# In-memory SQLite by default: a shared-cache database, so threads see the
# same tables. DATABASE_URL runs the SAME suite against PostgreSQL:
#   DATABASE_URL=postgres://localhost/usernames_test bundle exec rake test
if ENV["DATABASE_URL"].to_s.strip.empty?
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: "file::memory:?cache=shared")
else
  ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
end
ActiveRecord::Base.logger = Logger.new($stdout)
ActiveRecord::Base.logger.level = Logger::WARN

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

# The schema the install generator writes, per adapter (PRD §11.2): a
# byte-compared column ("C" on PostgreSQL; SQLite's default BINARY), a plain
# unique index in lowercase mode and a unique lower() expression in preserve
# mode, on a column that keeps the database's collation (the expression
# carries COLLATE "C"). The unique email index is the "unrelated constraint"
# the race wrapper must let through.
POSTGRESQL = ActiveRecord::Base.lease_connection.adapter_name.match?(/postg/i)
COLLATION = POSTGRESQL ? { collation: "C" } : {}

ActiveRecord::Schema.define(version: 1) do
  create_table :members, force: true do |t|
    t.string :username
    t.string :handle
    t.string :email
  end

  create_table :users, force: true do |t|
    t.string :username, **COLLATION
    t.string :email
    t.string :name
  end
  add_index :users, :username, unique: true, name: "index_users_on_username"
  add_index :users, :email, unique: true

  create_table :players, force: true do |t|
    t.string :handle
  end
  add_index :players, POSTGRESQL ? 'lower(handle COLLATE "C")' : "lower(handle)",
            unique: true, name: "index_players_on_lower_handle"
end

# The bare validator, on the attribute as supplied.
class Member < ApplicationRecord
  validates :username, username: true
end

# The README's one line.
class User < ApplicationRecord
  has_username
end

# The README's other column: kept case, dots and dashes, a shorter range.
class Player < ApplicationRecord
  has_username :handle, length: 2..24, case: :preserve, separators: %w[_ . -]
end

# People choose their own name: no generation, presence on create and on change.
class StrictUser < ApplicationRecord
  self.table_name = "users"
  has_username required: true
end

module UsernamesTestHelper
  FIXTURES = File.expand_path("fixtures", __dir__)

  def reset_configuration!
    Usernames.configuration = Usernames::Configuration.new
  end

  # with_config(length: 2..15, offensive: { severity: :severe }) { … }
  #
  # Runs the block under a fresh configuration with these options set the
  # way an initializer would set them, and puts the previous one back.
  def with_config(**options)
    previous = Usernames.configuration
    configuration = Usernames::Configuration.new
    options.each do |name, value|
      if value.is_a?(Hash)
        value.each { |nested, setting| configuration.public_send(name).public_send(:"#{nested}=", setting) }
      else
        configuration.public_send(:"#{name}=", value)
      end
    end
    Usernames.configuration = configuration
    yield configuration
  ensure
    Usernames.configuration = previous
  end

  # test/fixtures/username_table.csv as [input, expected reason, options].
  #
  # `input` is written as the inside of a Ruby double-quoted string (`\n`,
  # `\u{200B}`, `\xFF`), so invisible characters are visible in review.
  # `options` are `name=value` pairs: separators=_.- (each character one
  # separator; empty for none), case=preserve, edge_separators=true,
  # first_character=letter, length=2..15.
  def username_table
    CSV.read(File.join(FIXTURES, "username_table.csv"), headers: true).map do |row|
      [%("#{row['input']}").undump, row["expected"].to_sym, table_options(row["options"])]
    end
  end

  def table_options(text)
    text.to_s.split.to_h do |pair|
      name, value = pair.split("=", 2)
      [name.to_sym, table_option(name, value.to_s)]
    end
  end

  # Captures Rails.logger output for the duration of the block.
  def capture_log
    output = StringIO.new
    old_logger = Rails.logger
    Rails.logger = Logger.new(output)
    yield
    output.string
  ensure
    Rails.logger = old_logger
  end

  private

  def table_option(name, value)
    case name
    when "separators" then value.chars
    when "edge_separators" then value == "true"
    when "length" then Range.new(*value.split("..").map(&:to_i))
    else value.to_sym
    end
  end
end

# Base test class that includes the helper
class UsernamesTestCase < Minitest::Test
  include UsernamesTestHelper

  def setup
    reset_configuration!
    I18n.locale = :en
  end

  def teardown
    reset_configuration!
    I18n.locale = :en
  end
end
