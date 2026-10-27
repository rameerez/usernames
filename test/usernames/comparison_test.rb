# frozen_string_literal: true

require "test_helper"

# PRD §11.1: one comparison expression per adapter and case mode.
class ComparisonTest < UsernamesTestCase
  Comparison = Usernames::Comparison

  def on(adapter_name, &)
    ActiveRecord::Base.lease_connection.stub(:adapter_name, adapter_name, &)
  end

  def test_lowercase_mode_is_the_quoted_column_on_every_adapter
    %w[PostgreSQL SQLite Mysql2].each do |adapter|
      on(adapter) { assert_equal %("users"."username"), Comparison.sql(User, :username) }
    end
  end

  def test_preserve_mode_on_postgresql_lowercases_under_the_c_collation
    on("PostgreSQL") { assert_equal %(lower("players"."handle" COLLATE "C")), Comparison.sql(Player, :handle) }
    on("PostGIS") { assert_equal %(lower("players"."handle" COLLATE "C")), Comparison.sql(Player, :handle) }
  end

  def test_preserve_mode_on_sqlite_and_mysql_is_a_bare_lower
    %w[SQLite Mysql2 Trilogy].each do |adapter|
      on(adapter) { assert_equal %(lower("players"."handle")), Comparison.sql(Player, :handle) }
    end
  end

  def test_a_model_without_has_username_follows_the_configuration
    assert_equal %("members"."username"), Comparison.sql(Member, :username)

    with_config(case: :preserve) do
      assert_equal :preserve, Comparison.mode_for(Member, :username)
      on("PostgreSQL") { assert_equal %(lower("members"."username" COLLATE "C")), Comparison.sql(Member, :username) }
    end
  end

  def test_the_declared_mode_wins_over_the_configuration
    with_config(case: :preserve) { assert_equal :lowercase, Comparison.mode_for(User, :username) }
    assert_equal :preserve, Comparison.mode_for(Player, "handle")
  end

  def test_index_definitions
    assert_equal({ column: :username, name: "index_users_on_username", unique: true },
                 Comparison.index_definition(adapter: :postgresql, table: :users, column: :username, mode: :lowercase))
    assert_equal({ column: 'lower(handle COLLATE "C")', name: "index_players_on_lower_handle", unique: true },
                 Comparison.index_definition(adapter: "postgresql", table: "players", column: :handle, mode: :preserve))
    assert_equal "lower(handle)",
                 Comparison.index_definition(adapter: "sqlite3", table: :players, column: :handle,
                                             mode: :preserve)[:column]
    assert_equal "(lower(handle))",
                 Comparison.index_definition(adapter: "mysql2", table: :players, column: :handle,
                                             mode: :preserve)[:column]
    assert_equal "index_users_on_username",
                 Comparison.index_definition(adapter: :sqlite, table: "public.users", column: :username,
                                             mode: :lowercase)[:name]
  end

  # What the audit prints: a plain table as a symbol, a schema-qualified one
  # as the string literal Ruby can parse.
  def test_names_as_migration_arguments
    assert_equal ":users", Comparison.ruby_name("users")
    assert_equal ":username", Comparison.ruby_name(:username)
    assert_equal %("public.users"), Comparison.ruby_name("public.users")
    assert_equal %("my-table"), Comparison.ruby_name("my-table")
  end

  def test_column_collations
    assert_equal "C", Comparison.column_collation("postgresql")
    assert_equal "utf8mb4_bin", Comparison.column_collation("trilogy")
    assert_nil Comparison.column_collation("sqlite3")

    # Preserve mode on PostgreSQL: the expression carries COLLATE "C" itself.
    assert_nil Comparison.column_collation("postgresql", :preserve)
    assert_equal "C", Comparison.column_collation("postgresql", :lowercase)
    assert_equal "utf8mb4_bin", Comparison.column_collation("mysql2", :preserve), "MySQL's lower() follows the column"
  end

  def test_adapter_names
    assert_equal :postgresql, Comparison.adapter(ActiveRecord::Base.lease_connection) if POSTGRESQL
    assert_equal :sqlite, Comparison.adapter(ActiveRecord::Base.lease_connection) unless POSTGRESQL

    assert_equal :mysql, Comparison.adapter("MariaDB")
    error = assert_raises(Usernames::ConfigurationError) { Comparison.adapter("oracle_enhanced") }

    assert_match(/supports PostgreSQL, MySQL and SQLite; the "oracle_enhanced" adapter/, error.message)
  end

  # The expression is a bound predicate: the name is always a bind, never
  # interpolated, so a quote in it is only data.
  def test_helpers_bind_the_name
    sql = nil
    capture = ->(*, payload) { sql ||= payload[:sql] if payload[:sql].include?("users") }
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { User.find_by_username("o'brien") }

    refute_includes sql, "o'brien"
  end
end
