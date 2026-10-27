# frozen_string_literal: true

require "test_helper"

# For PG::PG_DIAG_* on a SQLite run too: the diagnostics are read the same way.
begin
  require "pg"
rescue LoadError
  nil
end

# Which unique index a RecordNotUnique came from (D-19), from the shapes each
# adapter reports it in.
class UniqueViolationTest < UsernamesTestCase
  # The parts of a PG::Result the diagnostics are read from.
  FakeResult = Struct.new(:fields) do
    def error_field(field) = fields[field]
  end
  FakeCause = Struct.new(:result)
  FakeIndex = Struct.new(:name, :columns)

  # Indexes as a connection reads them back.
  class FakeConnection
    def initialize(indexes) = @indexes = indexes
    def indexes(_table) = @indexes
  end

  # A connection that cannot read indexes (no database, a permissions quirk).
  class BrokenConnection
    def indexes(_table) = raise(ActiveRecord::ConnectionNotEstablished, "no database")
  end

  def violation(message, cause: nil)
    error = ActiveRecord::RecordNotUnique.new(message)
    error.define_singleton_method(:cause) { cause } if cause
    error
  end

  def of?(error, table: "users", column: :username, **)
    Usernames::UniqueViolation.of?(error, table: table, column: column, **)
  end

  # --- SQLite ------------------------------------------------------------------------------------

  def test_sqlite_column_message
    assert of?(violation("SQLite3::ConstraintException: UNIQUE constraint failed: users.username"))
    assert of?(violation("UNIQUE constraint failed: users.tenant_id, users.username"))
    refute of?(violation("SQLite3::ConstraintException: UNIQUE constraint failed: users.email"))
    refute of?(violation("UNIQUE constraint failed: members.username"))
  end

  def test_sqlite_expression_index_message
    message = "SQLite3::ConstraintException: UNIQUE constraint failed: index 'index_players_on_lower_handle'"

    assert of?(violation(message), table: "players", column: :handle)
    refute of?(violation("UNIQUE constraint failed: index 'index_players_on_lower_email'"), table: "players",
                                                                                            column: :handle)
  end

  # --- PostgreSQL --------------------------------------------------------------------------------

  def test_postgresql_diagnostics
    skip "the pg gem is not loaded" unless defined?(PG)

    fields = { PG::PG_DIAG_CONSTRAINT_NAME => "index_users_on_username", PG::PG_DIAG_TABLE_NAME => "users" }
    error = violation("PG::UniqueViolation: ERROR: duplicate key", cause: FakeCause.new(FakeResult.new(fields)))

    assert of?(error)
    refute of?(error, table: "accounts"), "a violation reported on another table"

    email = { PG::PG_DIAG_CONSTRAINT_NAME => "index_users_on_email", PG::PG_DIAG_TABLE_NAME => "users" }
    email_error = violation("duplicate key", cause: FakeCause.new(FakeResult.new(email)))

    refute of?(email_error, connection: FakeConnection.new([FakeIndex.new("index_users_on_email", ["email"])]))
  end

  def test_postgresql_message_without_diagnostics
    message = %(PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint "users_handle_key"\n) +
              %(DETAIL:  Key (lower(handle::text COLLATE "C"))=(javi) already exists.)
    expression = FakeIndex.new("users_handle_key", %(lower(((handle)::text COLLATE "C"))))

    assert of?(violation(message), column: :handle, connection: FakeConnection.new([expression]))
    refute of?(violation(message), column: :username, connection: FakeConnection.new([expression]))
    refute of?(violation(message), column: :handle, connection: FakeConnection.new([]))
  end

  def test_an_index_the_gem_did_not_name_is_confirmed_by_its_columns
    message = %(duplicate key value violates unique constraint "uniq_login")

    assert of?(violation(message), connection: FakeConnection.new([FakeIndex.new("uniq_login", ["username"])]))
    assert of?(violation(message),
               connection: FakeConnection.new([FakeIndex.new("uniq_login", %w[tenant_id username])]))
    refute of?(violation(message), connection: FakeConnection.new([FakeIndex.new("uniq_login", ["username_hash"])]))
    refute of?(violation(message), connection: FakeConnection.new([FakeIndex.new("uniq_login", "lower(usernames)")]))
  end

  def test_the_configured_unique_index_is_recognised
    message = %(duplicate key value violates unique constraint "uniq_login")

    assert of?(violation(message), index: "uniq_login", connection: BrokenConnection.new)
    assert of?(violation(message), index: :uniq_login, connection: BrokenConnection.new)
    refute of?(violation(message), connection: BrokenConnection.new), "unreadable indexes: only known names"
  end

  def test_the_gems_own_index_names_need_no_lookup
    assert of?(violation(%(violates unique constraint "index_users_on_lower_username")),
               connection: BrokenConnection.new)
  end

  def test_reads_indexes_from_the_default_connection_when_none_is_given
    assert of?(violation(%(violates unique constraint "index_users_on_email")), column: :email)
    refute of?(violation(%(violates unique constraint "index_users_on_email")))
  end

  # --- MySQL -------------------------------------------------------------------------------------

  def test_mysql_key_message
    assert of?(violation("Mysql2::Error: Duplicate entry 'javi' for key 'users.index_users_on_username'"))
    assert of?(violation("Mysql2::Error: Duplicate entry 'javi' for key 'index_users_on_username'"))
    refute of?(violation("Duplicate entry 'javi' for key 'accounts.index_accounts_on_username'"))
    refute of?(violation("Trilogy::ProtocolError: Duplicate entry 'a@b' for key 'users.index_users_on_email'"))
  end

  # --- anything else -------------------------------------------------------------------------------

  def test_an_unrecognised_message_is_not_ours
    refute of?(violation("something else went wrong"))
  end

  def test_a_real_violation_on_this_database
    User.delete_all
    User.create!(username: "javi", email: "j@example.com")

    username = assert_raises(ActiveRecord::RecordNotUnique) do
      User.insert_all!([{ username: "javi", email: "k@example.com" }])
    end
    email = assert_raises(ActiveRecord::RecordNotUnique) do
      User.insert_all!([{ username: "ana", email: "j@example.com" }])
    end

    assert of?(username)
    refute of?(email)
  ensure
    User.delete_all
  end
end
