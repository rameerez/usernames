# frozen_string_literal: true

require "test_helper"

# For PG::PG_DIAG_* on a SQLite run too: the diagnostics are read the same way.
begin
  require "pg"
rescue LoadError
  nil
end

# Which unique index a RecordNotUnique came from, from the shapes each
# adapter reports it in.
class UniqueViolationTest < UsernamesTestCase
  # The parts of a PG::Result the diagnostics are read from.
  FakeResult = Struct.new(:fields) do
    def error_field(field) = fields[field]
  end
  FakeCause = Struct.new(:result)
  # A collation that compares names with their underscores taken out.
  class IgnoringUnderscores
    def compare(left, right) = left.delete("_") <=> right.delete("_")
  end

  # A connection that cannot read indexes (no database, a permissions quirk).
  class BrokenConnection
    def indexes(_table) = raise(ActiveRecord::ConnectionNotEstablished, "no database")
  end

  def setup
    super
    connection.create_table(:violation_users, force: true) do |t|
      t.string :username, **COLLATION
      t.string :handle, **COLLATION
      t.string :tenant
      t.integer :active
    end
  end

  def teardown
    connection.drop_table(:violation_users, if_exists: true)
    super
  end

  def connection
    ActiveRecord::Base.lease_connection
  end

  # An index on violation_users the gem did not name.
  def index(columns, name: "uniq_login", **)
    connection.add_index(:violation_users, columns, unique: true, name: name, **)
  end

  # A second unique index on users.username for the block, then none.
  def with_users_index(expression)
    User.delete_all
    connection.add_index(:users, expression, unique: true, name: "index_users_on_second")
    yield
  ensure
    connection.remove_index(:users, name: "index_users_on_second", if_exists: true)
    User.delete_all
  end

  def diagnostics(fields)
    FakeCause.new(FakeResult.new(fields))
  end

  def violation(message, cause: nil)
    error = ActiveRecord::RecordNotUnique.new(message)
    error.define_singleton_method(:cause) { cause } if cause
    error
  end

  # `index` and `mode` are what the column's rules would say: config.unique_index and its case.
  def of?(error, table: "users", column: :username, connection: nil, **said)
    rules = Usernames.configuration.rules_for(unique_index: said[:index], case: said.fetch(:mode, :lowercase))
    Usernames::UniqueViolation.of?(error, table: table, column: column, rules: rules, connection: connection,
                                          conflict: said[:conflict])
  end

  # --- SQLite ------------------------------------------------------------------------------------

  # SQLite names only the columns: the column alone, with an identity index on it.
  def test_sqlite_column_message
    assert of?(violation("SQLite3::ConstraintException: UNIQUE constraint failed: users.username"))
    refute of?(violation("SQLite3::ConstraintException: UNIQUE constraint failed: users.email"))
    refute of?(violation("UNIQUE constraint failed: members.username"))
  end

  # (tenant, username) is unique, but it is not who has the name.
  def test_sqlite_composite_columns_are_not_the_identity
    refute of?(violation("UNIQUE constraint failed: users.tenant_id, users.username"))
  end

  def test_sqlite_column_message_needs_an_identity_index_on_the_column
    message = "UNIQUE constraint failed: violation_users.username"

    refute of?(violation(message), table: "violation_users"), "no index at all"
    index(:username, where: "active = 1")

    refute of?(violation(message), table: "violation_users"), "only a partial index"
    connection.remove_index(:violation_users, name: "uniq_login")
    index(:username, name: "uniq_whole")

    assert of?(violation(message), table: "violation_users")
  end

  def test_sqlite_expression_index_message
    message = "SQLite3::ConstraintException: UNIQUE constraint failed: index 'index_players_on_lower_handle'"

    assert of?(violation(message), table: "players", column: :handle, mode: :preserve)
    refute of?(violation("UNIQUE constraint failed: index 'index_players_on_lower_email'"), table: "players",
                                                                                            column: :handle)
  end

  # --- PostgreSQL --------------------------------------------------------------------------------

  def test_postgresql_diagnostics
    skip "the pg gem is not loaded" unless defined?(PG)

    fields = { PG::PG_DIAG_CONSTRAINT_NAME => "index_users_on_username", PG::PG_DIAG_TABLE_NAME => "users" }
    error = violation("PG::UniqueViolation: ERROR: duplicate key", cause: diagnostics(fields))

    assert of?(error)
    refute of?(error, table: "accounts"), "a violation reported on another table"

    email = { PG::PG_DIAG_CONSTRAINT_NAME => "index_users_on_email", PG::PG_DIAG_TABLE_NAME => "users" }

    refute of?(violation("duplicate key", cause: diagnostics(email)))
  end

  # A schema-qualified table keeps its schema: the same table name in another
  # schema is somebody else's violation.
  def test_postgresql_schema_qualification
    skip "the pg gem is not loaded" unless defined?(PG)

    fields = { PG::PG_DIAG_CONSTRAINT_NAME => "index_users_on_username", PG::PG_DIAG_TABLE_NAME => "users",
               PG::PG_DIAG_SCHEMA_NAME => "public" }
    error = violation("duplicate key", cause: diagnostics(fields))

    assert of?(error, table: "public.users")
    assert of?(error, table: "users"), "an unqualified table is whatever the search path finds"
    refute of?(error, table: "tenant_7.users")
  end

  def test_postgresql_message_without_diagnostics
    message = %(PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint "uniq_handle"\n) +
              %(DETAIL:  Key (lower(handle::text COLLATE "C"))=(javi) already exists.)

    refute of?(violation(message), table: "violation_users", column: :handle, mode: :preserve), "no such index"
    index(POSTGRESQL ? 'lower(handle COLLATE "C")' : "lower(handle)", name: "uniq_handle")

    assert of?(violation(message), table: "violation_users", column: :handle, mode: :preserve)
    refute of?(violation(message), table: "violation_users", column: :username, mode: :preserve)
  end

  # An index the gem did not name is the identity only when it passes the
  # comparison contract: an app's own prefix or tenant index is not.
  def test_an_index_the_gem_did_not_name_is_confirmed_by_the_contract
    message = %(duplicate key value violates unique constraint "uniq_login")
    verdicts = [[:username, {}], [%i[tenant username], {}], [:username, { where: "active = 1" }],
                ["substr(username, 1, 3)", {}], [:handle, {}]].map do |columns, options|
      connection.remove_index(:violation_users, name: "uniq_login", if_exists: true)
      index(columns, **options)
      of?(violation(message), table: "violation_users")
    end

    assert_equal [true, false, false, false, false], verdicts
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
    index(:username)

    assert of?(violation(%(violates unique constraint "uniq_login")), table: "violation_users")
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

  # An app's own unique index over a prefix of the name: its violation is a
  # real error, not "has already been taken" for a name nobody has.
  def test_an_apps_own_expression_index_propagates_through_save
    User.delete_all
    connection.add_index(:users, "substr(username, 1, 3)", unique: true, name: "index_users_on_prefix")
    User.create!(username: "alice", email: "a@example.com")
    alicia = User.new(username: "alicia", email: "b@example.com")

    assert_predicate alicia, :valid?
    assert_raises(ActiveRecord::RecordNotUnique) { alicia.save }
    assert_empty alicia.errors
    assert User.username_available?("alicia")
  ensure
    connection.remove_index(:users, name: "index_users_on_prefix", if_exists: true)
    User.delete_all
  end

  # SQLite's column message names no index. With a second unique index on
  # the column (one that ignores underscores), the violation is the app's
  # own constraint unless another row really has the name.
  def test_a_second_unique_index_on_the_column_needs_a_real_conflict
    skip "SQLite only" if POSTGRESQL
    connection.raw_connection.collation("NOPUNCT", IgnoringUnderscores.new)
    with_users_index("username COLLATE NOPUNCT") do
      User.create!(username: "javi_r", email: "a@example.com")
      javir = User.new(username: "javir", email: "b@example.com")

      assert_predicate javir, :valid?
      assert_raises(ActiveRecord::RecordNotUnique) { javir.save }
      assert_empty javir.errors
      twin = User.new(username: "javi_r", email: "c@example.com")

      refute twin.save(validate: false), "the same name, past validation, is still taken"
      assert_equal [{ error: :taken }], twin.errors.details[:username]
    end
  end

  # A legacy JAVI under a second, NOCASE index: the new javi collides with
  # nobody the gem compares equal, so the error is the app's index's.
  def test_a_second_nocase_index_with_a_legacy_row_propagates
    skip "SQLite only" if POSTGRESQL
    with_users_index("username COLLATE NOCASE") do
      connection.execute("INSERT INTO users (username, email) VALUES ('JAVI', 'a@example.com')") # as stored before the gem

      assert_raises(ActiveRecord::RecordNotUnique) { User.create(username: "javi", email: "b@example.com") }
    end
  end

  def test_an_ambiguous_column_message_without_a_conflict_query_is_not_ours
    message = "UNIQUE constraint failed: violation_users.username"
    index(:username, name: "uniq_whole")
    index(:username, name: "uniq_active", where: "active = 1")

    refute of?(violation(message), table: "violation_users")
    refute of?(violation(message), table: "violation_users", conflict: -> { false })
    assert of?(violation(message), table: "violation_users", conflict: -> { true })
  end
end
