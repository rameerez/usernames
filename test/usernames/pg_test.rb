# frozen_string_literal: true

require "test_helper"
require "usernames/audit"

# PRD §11.3–11.4, live on PostgreSQL: real concurrent races, the savepoint,
# unique-violation diagnostics, the "C" comparison against ICU and
# nondeterministic collations, and the audit's verdict on citext.
#
#   DATABASE_URL=postgres://localhost/usernames_test bundle exec rake test
return unless POSTGRESQL

# A User whose saves can be held at the race window: after validation said
# the name was free, before the INSERT or UPDATE.
class PostgresRacer < ApplicationRecord
  self.table_name = "users"
  has_username

  cattr_accessor :gate
  cattr_accessor :rival
  cattr_accessor :competitor
  cattr_accessor :before_create_calls, default: 0
  cattr_accessor :after_create_calls, default: 0
  cattr_accessor :after_commit_calls, default: 0

  after_validation { gate&.call(self) }
  after_validation { rival&.call(self) }
  before_create { self.class.before_create_calls += 1 }
  before_create { competitor&.call(self) }
  before_update { competitor&.call(self) }
  after_create { self.class.after_create_calls += 1 }
  after_commit(on: :create) { self.class.after_commit_calls += 1 }
end

class PostgresTest < UsernamesTestCase
  def setup
    super
    User.delete_all
    Player.delete_all
    PostgresRacer.gate = PostgresRacer.rival = PostgresRacer.competitor = nil
    PostgresRacer.before_create_calls = PostgresRacer.after_create_calls = PostgresRacer.after_commit_calls = 0
  end

  def teardown
    PostgresRacer.gate = nil
    User.delete_all
    Player.delete_all
    super
  end

  def connection
    ActiveRecord::Base.lease_connection
  end

  def take(name, email: "rival-#{SecureRandom.hex(4)}@example.com")
    connection.execute("INSERT INTO users (username, email) VALUES (#{connection.quote(name)}, #{connection.quote(email)})")
  end

  # Runs each block in its own thread and connection, all held at the race
  # window until every one has validated, then released together.
  def race(*saves)
    arrived = Queue.new
    release = Queue.new
    PostgresRacer.gate = lambda do |_record|
      arrived << true
      release.pop
    end
    threads = saves.map do |save|
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { save.call } }
    end
    saves.size.times { arrived.pop }
    saves.size.times { release << true }
    results = threads.map(&:value)
    # Each racer checked its connection out for the block only: none may be
    # left leased to a finished thread, waiting for the pool to reap it.
    leased = ActiveRecord::Base.connection_pool.connections.count { |held| held.in_use? && held.owner != Thread.current }

    assert_equal 0, leased, "a racer's connection outlived its with_connection block"
    results
  ensure
    PostgresRacer.gate = nil
  end

  # --- races, for real -----------------------------------------------------------------------------

  def test_a_typed_create_race_ends_in_taken_for_the_loser
    records = Array.new(2) { |index| PostgresRacer.new(username: "javi", email: "racer#{index}@example.com") }

    results = race(*records.map { |record| -> { record.save } })

    assert_equal([false, true], results.sort_by { |result| result ? 1 : 0 })
    loser = records.find(&:new_record?)

    assert_equal [{ error: :taken }], loser.errors.details[:username]
    assert_equal 1, User.where(username: "javi").count
  end

  def test_a_typed_create_race_with_save_bang_raises_record_invalid
    records = Array.new(2) { |index| PostgresRacer.new(username: "javi", email: "racer#{index}@example.com") }

    results = race(*records.map do |record|
      lambda do
        record.save!
      rescue ActiveRecord::RecordInvalid => e
        e
      end
    end)

    error = results.grep(ActiveRecord::RecordInvalid).first

    refute_nil error
    assert_equal ["Username has already been taken"], error.record.errors.full_messages
  end

  def test_a_generated_create_race_redraws_the_loser
    names = %w[quiet_otter_42 calm_heron_17]
    records = Array.new(2) { |index| PostgresRacer.new(email: "racer#{index}@example.com") }

    Usernames::Generator.stub(:candidates, ->(**) { names.dup }) do
      results = race(*records.map { |record| -> { record.save } })

      assert_equal [true, true], results
    end

    assert_equal %w[calm_heron_17 quiet_otter_42], records.map(&:username).sort
    assert(records.all?(&:username_generated?))
  end

  def test_a_typed_update_race_ends_in_taken_for_the_loser
    records = %w[ana pedro].map { |name| PostgresRacer.create!(username: name, email: "#{name}@example.com") }

    results = race(*records.map { |record| -> { record.update(username: "javi") } })

    assert_equal([false, true], results.sort_by { |result| result ? 1 : 0 })
    loser = records.find { |record| record.errors.any? }

    assert_equal [{ error: :taken }], loser.errors.details[:username]
    assert_equal 1, User.where(username: "javi").count
  end

  # --- the savepoint, live --------------------------------------------------------------------------

  def test_outer_writes_survive_a_redraw
    PostgresRacer.rival = ->(record) { take(record.username) }

    ActiveRecord::Base.transaction do
      User.create!(username: "before", email: "before@example.com")
      PostgresRacer.create!(email: "racer@example.com")
      User.create!(username: "after", email: "after@example.com")
    end

    assert_equal 4, User.count
    assert User.exists?(username: "before")
    assert User.exists?(username: "after")
  end

  def test_an_unrelated_violation_propagates_and_aborts_nothing_else
    User.create!(username: "someone", email: "dup@example.com")

    error = assert_raises(ActiveRecord::RecordNotUnique) { User.create(username: "javi", email: "dup@example.com") }

    assert_match(/index_users_on_email/, error.message)
  end

  def test_redraws_terminate
    PostgresRacer.competitor = ->(record) { take(record.username) }
    record = PostgresRacer.new(email: "racer@example.com")

    refute record.save
    assert_equal [{ error: :taken }], record.errors.details[:username]
    assert_equal 4, PostgresRacer.before_create_calls
  end

  def test_callbacks_run_per_attempt_before_and_once_after
    PostgresRacer.rival = ->(record) { take(record.username) }

    PostgresRacer.create!(email: "racer@example.com")

    assert_equal 2, PostgresRacer.before_create_calls
    assert_equal 1, PostgresRacer.after_create_calls
    assert_equal 1, PostgresRacer.after_commit_calls
  end

  def test_unique_violation_reads_the_server_diagnostics
    take("javi")
    username = assert_raises(ActiveRecord::RecordNotUnique) { take("javi") }
    take("ana", email: "e@example.com")
    email = assert_raises(ActiveRecord::RecordNotUnique) { take("pedro", email: "e@example.com") }

    assert_kind_of PG::UniqueViolation, username.cause
    assert Usernames::UniqueViolation.of?(username, table: "users", column: :username)
    refute Usernames::UniqueViolation.of?(email, table: "users", column: :username)
  end

  # --- preserve mode: the expression, its index and the bound predicate -------------------------------

  def test_preserve_mode_uses_the_expression_index
    Player.create!(handle: "Javi")
    plan = connection.transaction do
      connection.execute("SET LOCAL enable_seqscan = off")
      Player.where("#{Usernames::Comparison.sql(Player, :handle)} = ?", "javi").explain.inspect
    end

    assert_includes plan, "index_players_on_lower_handle"
  end

  def test_preserve_mode_helpers_and_validation_run_as_bound_predicates
    player = Player.create!(handle: "Javi")

    assert_equal player, Player.find_by_handle("JAVI")
    refute Player.handle_available?("jAVI")
    refute_predicate Player.new(handle: "javi"), :valid?
    assert player.update(handle: "JAVI"), "a case-only change excludes the record itself"
    assert_equal %w[JAVI], Player.pluck(:handle)
    refute_includes Player.suggest_handles("javi"), "javi"
  end

  # The install generator leaves a preserve-mode column in the database's
  # collation: equality goes through COLLATE "C" anyway, and ORDER BY keeps
  # sorting the way people read instead of every capital first.
  def test_preserve_mode_keeps_the_columns_own_order_and_still_compares_bytewise
    collation = connection.select_value("SELECT datcollate FROM pg_database WHERE datname = current_database()")
    skip "this database sorts bytewise already (#{collation})" if %w[C POSIX].include?(collation)

    %w[bob Alice carol].each { |handle| Player.create!(handle: handle) }

    assert_equal %w[Alice bob carol], Player.order(:handle).pluck(:handle)
    assert_equal "Alice", Player.find_by_handle("ALICE").handle
    refute_predicate Player.new(handle: "BOB"), :valid?
    assert_match(/✓ character varying, collation .* \(compared through COLLATE "C"\)/, audit_of(Player, :handle))
  end

  # --- collations ---------------------------------------------------------------------------------

  # PRD §11.1: under a Turkish ICU collation lower('I') is 'ı', so a
  # lower() index there would let `HIJ` and `hij` be two people.
  def test_the_c_collation_avoids_the_turkish_i
    skip "this PostgreSQL has no ICU" unless collation?("tr-x-icu")

    with_scratch_table(%(name varchar COLLATE "tr-x-icu")) do
      connection.execute("INSERT INTO usernames_scratch (name) VALUES ('HIJ')")

      assert_equal "hıj", connection.select_value("SELECT lower(name) FROM usernames_scratch")
      assert_equal "hij", connection.select_value(%(SELECT lower(name COLLATE "C") FROM usernames_scratch))
      assert_equal 0, connection.select_value("SELECT count(*) FROM usernames_scratch WHERE lower(name) = 'hij'")
      assert_equal 1, connection.select_value(%(SELECT count(*) FROM usernames_scratch
                                                WHERE lower(name COLLATE "C") = 'hij'))
    end
  end

  # A nondeterministic collation can make john.doe equal johndoe (D-6 says
  # they are two people); "C" never does, and the audit flags the collation.
  def test_a_nondeterministic_collation_is_avoided_and_reported
    skip "this PostgreSQL has no ICU" unless collation?("und-x-icu")

    with_ignore_punctuation_collation { assert_nondeterministic_collation_is_avoided }
  end

  def assert_nondeterministic_collation_is_avoided
    with_scratch_table("username varchar COLLATE usernames_ignore_punctuation") do
      connection.execute("INSERT INTO usernames_scratch (username) VALUES ('john.doe')")

      assert_equal 1, connection.select_value("SELECT count(*) FROM usernames_scratch WHERE username = 'johndoe'")
      assert_equal 0, connection.select_value(%(SELECT count(*) FROM usernames_scratch
                                                WHERE username COLLATE "C" = 'johndoe'))
      assert_match(/nondeterministic/, audit_of_scratch)
    end
  end

  def test_the_audit_reports_citext_as_incompatible
    connection.execute("CREATE EXTENSION IF NOT EXISTS citext")

    with_scratch_table("username citext") do
      assert_match(/✗ citext is incompatible/, audit_of_scratch)
    end
  end

  def test_the_audit_of_a_populated_column_on_postgresql
    take("JAVI")
    take("javi")

    output = StringIO.new
    Usernames::Audit.new(User).report(output)

    assert_match(/✓ character varying, collation "C"/, output.string)
    assert_match(/✓ index_users_on_username matches the lowercase mode/, output.string)
    assert_match(/"JAVI" → "javi"/, output.string)
    assert_match(/"javi": #\d+ "JAVI", #\d+ "javi"|"javi": #\d+ "javi", #\d+ "JAVI"/, output.string)
  end

  def test_the_audit_reports_a_default_collation_column
    with_scratch_table("username varchar") do
      default = connection.select_value("SELECT datcollate FROM pg_database WHERE datname = current_database()")

      assert_match(/collation #{Regexp.escape(default.inspect)}/, audit_of_scratch) unless default == "C"
    end
  end

  private

  def with_ignore_punctuation_collation
    connection.execute(<<~SQL)
      DROP COLLATION IF EXISTS usernames_ignore_punctuation;
      CREATE COLLATION usernames_ignore_punctuation (provider = icu, locale = 'und-u-ka-shifted', deterministic = false);
    SQL
    yield
  ensure
    connection.execute("DROP COLLATION IF EXISTS usernames_ignore_punctuation")
  end

  def collation?(name)
    connection.select_value("SELECT 1 FROM pg_collation WHERE collname = #{connection.quote(name)}") == 1
  end

  def with_scratch_table(columns)
    connection.execute("DROP TABLE IF EXISTS usernames_scratch")
    connection.execute("CREATE TABLE usernames_scratch (id bigserial PRIMARY KEY, #{columns})")
    connection.schema_cache.clear_data_source_cache!("usernames_scratch")
    yield
  ensure
    connection.execute("DROP TABLE IF EXISTS usernames_scratch")
  end

  def audit_of_scratch
    model = Class.new(ApplicationRecord) do
      self.table_name = "usernames_scratch"
      def self.name = "Scratch"
    end
    audit_of(model, :username)
  end

  def audit_of(model, column)
    output = StringIO.new
    Usernames::Audit.new(model, column).report(output)
    output.string
  end
end
