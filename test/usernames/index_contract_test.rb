# frozen_string_literal: true

require "test_helper"
require "usernames/audit"

# Comparison::IndexContract against indexes the database itself reads back:
# what the installer, the audit and UniqueViolation accept as "the index that
# makes usernames unique".
class IndexContractTest < UsernamesTestCase
  Contract = Usernames::Comparison::IndexContract
  TABLE = :contract_users

  # A linguistic collation each adapter ships: NOCASE, and ICU's root locale.
  LINGUISTIC = POSTGRESQL ? '"und-x-icu"' : "NOCASE"

  def setup
    super
    create_table
  end

  def teardown
    connection.drop_table(TABLE, if_exists: true)
    super
  end

  # --- what passes ----------------------------------------------------------------------------------

  def test_a_plain_unique_index_in_lowercase_mode
    assert_nil verdict(:username)
  end

  def test_the_one_harmless_condition_is_is_not_null
    assert_nil verdict(:username, where: "username IS NOT NULL")
  end

  def test_the_comparison_expression_in_preserve_mode
    assert_nil verdict(POSTGRESQL ? 'lower(username COLLATE "C")' : "lower(username)", mode: :preserve)
  end

  # --- what does not --------------------------------------------------------------------------------

  def test_an_index_that_is_not_unique
    assert_equal "isn't unique", verdict(:username, unique: false)
  end

  # Two inactive accounts could share a name.
  def test_a_partial_index
    assert_match(/\Aonly covers rows WHERE \(?active = 1\)?\z/, verdict(:username, where: "active = 1"))
  end

  def test_a_composite_index
    assert_equal "is on tenant, username, not username", verdict(%i[tenant username])
  end

  def test_an_expression_that_merely_mentions_the_column
    assert_match(/\Ais on an unsupported expression: substr\(.*username.*\)\z/, verdict("substr(username, 1, 3)"))
  end

  # A column whose name merely contains "username is not null" is a
  # condition on another column: two rows with it false share a name.
  def test_a_condition_on_a_column_named_like_the_null_test
    assert_match(/\Aonly covers rows WHERE "?usernameisnotnull"?\z/, verdict(:username, where: '"usernameisnotnull"'))
    assert_match(/\Aonly covers rows WHERE/, verdict(:username, where: "username IS NOT NULL AND active = 1"))
    assert_match(/\Aonly covers rows WHERE/, verdict(:username, where: "active IS NOT NULL"))
  end

  # "user name" is another column, however its letters squeeze.
  def test_a_quoted_column_that_is_not_the_username
    key = POSTGRESQL ? 'lower("user name" COLLATE "C")' : 'lower("user name")'

    assert_match(/\Ais on lower\(.*"user name".*\), not lower\(username/, verdict(key, mode: :preserve))
    assert_match(/\Ais on user name, not username\z/, verdict(["user name"]))
  end

  # The shapes each database prints back, and the ones it does not.
  def test_quoted_and_parenthesised_spellings_of_the_same_index
    assert_nil verdict('"username"', where: '("username" IS NOT NULL)')
    if POSTGRESQL
      assert_nil verdict('lower((username)::text COLLATE "C")', mode: :preserve)
      assert_nil verdict("((username)::text)")
    else
      assert_nil verdict('lower("username")', mode: :preserve)
    end

    assert_match(/\Ais on lower\(lower\(/, verdict("lower(lower(username))", mode: :preserve))
    assert_match(/\Ais on an unsupported expression: /, verdict("trim(username)", mode: :preserve))
    assert_match(/\Ais on an unsupported expression/, verdict("(username || 'x')"))
  end

  def test_the_wrong_mode
    assert_match(/\Ais on username, not lower\(username/, verdict(:username, mode: :preserve))
    assert_match(/\Ais on lower\(.*\), not username\z/, verdict("lower(username)"))
  end

  def test_preserve_mode_on_postgresql_needs_the_c_collation_in_the_expression
    skip "PostgreSQL only" unless POSTGRESQL

    assert_match(/not lower\(username COLLATE "C"\)/, verdict("lower(username)", mode: :preserve))
  end

  def test_an_index_with_a_collation_of_its_own
    assert_match(/\Acompares under collation "#{LINGUISTIC.delete('"')}", not byte by byte\z/,
                 verdict("username COLLATE #{LINGUISTIC}"))
  end

  def test_a_column_with_a_linguistic_collation
    create_table(collation: LINGUISTIC.delete('"'))

    assert_match(/\Ais on a column compared under collation "#{LINGUISTIC.delete('"')}"/, verdict(:username))
  end

  # In lowercase mode the queries compare the column under its own
  # collation, so a byte-wise collation on the index alone is not enough.
  def test_a_bytewise_index_on_a_linguistic_column
    create_table(collation: LINGUISTIC.delete('"'))

    assert_match(/\Ais on a column compared under collation "#{LINGUISTIC.delete('"')}", not byte by byte\z/,
                 verdict("username COLLATE #{POSTGRESQL ? '"C"' : 'BINARY'}"))
  end

  # The schema as written by hand: the index takes javi and JAVI as two
  # names, while the query the gem asks finds both.
  def test_a_binary_index_on_a_nocase_column_is_not_the_contract
    skip "SQLite only" if POSTGRESQL
    connection.drop_table(TABLE)
    connection.execute("CREATE TABLE #{TABLE} (id INTEGER PRIMARY KEY, username VARCHAR COLLATE NOCASE)")
    connection.execute("CREATE UNIQUE INDEX binary_on_nocase ON #{TABLE} (username COLLATE BINARY)")
    connection.execute("INSERT INTO #{TABLE} (username) VALUES ('javi'), ('JAVI')")

    assert_equal 2, connection.select_value("SELECT count(*) FROM #{TABLE} WHERE username = 'javi'")
    index = connection.indexes(TABLE).find { |each| each.name == "binary_on_nocase" }

    assert_match(/compared under collation "NOCASE"/, contract.violation(index))
    audit = StringIO.new
    Usernames::Audit.new(Class.new(ActiveRecord::Base) { self.table_name = TABLE.to_s }.tap do |model|
      model.define_singleton_method(:name) { "ContractUser" }
    end).report(audit)

    assert_match(/VARCHAR, COLLATE NOCASE: the contract is SQLite's default BINARY/, audit.string)
    assert_match(/binary_on_nocase \(unique on username\) — is on a column compared under collation "NOCASE"/,
                 audit.string)
  end

  def test_preserve_mode_on_postgresql_ignores_the_columns_collation
    skip "PostgreSQL only" unless POSTGRESQL
    create_table(collation: "und-x-icu")

    assert_nil verdict('lower(username COLLATE "C")', mode: :preserve), "the expression carries its own collation"
  end

  def test_an_invalid_index
    index = ActiveRecord::ConnectionAdapters::IndexDefinition.new(TABLE.to_s, "broken", true, ["username"],
                                                                  valid: false)

    assert_match(/\Aisn't valid/, contract.violation(index))
  end

  def test_mysql_compares_under_the_columns_collation
    columns = { "username" => "utf8mb4_0900_ai_ci", "handle" => "utf8mb4_bin" }
    fake = Struct.new(:adapter_name) do
      define_method(:columns) do |_table|
        columns.map { |name, collation| Struct.new(:name, :collation).new(name, collation) }
      end
    end.new("Mysql2")
    index = ->(column) { ActiveRecord::ConnectionAdapters::IndexDefinition.new("users", "i", true, [column]) }

    assert_match(/utf8mb4_0900_ai_ci/, Contract.new(fake, table: :users, column: :username, mode: :lowercase)
                                         .violation(index.call("username")))
    assert_nil Contract.new(fake, table: :users, column: :handle, mode: :lowercase).violation(index.call("handle"))
  end

  # --- the rest of its surface ----------------------------------------------------------------------

  def test_mentions_lists_every_index_involving_the_column
    contract = self.contract
    index = ->(columns) { ActiveRecord::ConnectionAdapters::IndexDefinition.new(TABLE.to_s, "i", true, columns) }

    assert contract.mentions?(index.call(%w[tenant username]))
    assert contract.mentions?(index.call(%(lower(((username)::text COLLATE "C")))))
    refute contract.mentions?(index.call(["username_hash"]))
    refute contract.mentions?(index.call("lower(usernames)"))
    refute contract.mentions?(index.call('lower("user name")'))
    assert contract.mentions?(index.call("lower(USERNAME)")), "a bare name in any case"
    refute contract.mentions?(index.call(%(lower("USERNAME")))), "a quoted one exactly"
  end

  def test_the_definition_is_the_gems_own_index
    assert_equal({ column: :username, name: "index_contract_users_on_username", unique: true }, contract.definition)
    assert_equal "index_contract_users_on_lower_username", contract(mode: :preserve).definition[:name]
  end

  private

  def connection
    ActiveRecord::Base.lease_connection
  end

  def create_table(collation: nil)
    connection.create_table(TABLE, force: true) do |t|
      t.string :username, **(collation ? { collation: collation } : COLLATION)
      t.string :tenant
      t.integer :active
      POSTGRESQL ? t.boolean(:usernameisnotnull) : t.integer(:usernameisnotnull)
      t.string "user name"
    end
  end

  def contract(mode: :lowercase)
    Contract.new(connection, table: TABLE, column: :username, mode: mode)
  end

  # Adds the index, reads it back as the database spells it, and returns why
  # it does not enforce the contract (nil when it does).
  def verdict(columns, mode: :lowercase, unique: true, **)
    connection.remove_index(TABLE, name: "probe", if_exists: true)
    connection.add_index(TABLE, columns, unique: unique, name: "probe", **)
    index = connection.indexes(TABLE).find { |each| each.name == "probe" }
    contract(mode: mode).violation(index)
  end
end
