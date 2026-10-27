# frozen_string_literal: true

require "test_helper"
require "rake"
require "usernames/audit"
require "usernames/reserved/listing"

class RakeTasksTest < UsernamesTestCase
  def setup
    super
    @rake = Rake::Application.new
    Rake.application = @rake
    load File.expand_path("../../lib/tasks/usernames.rake", __dir__)
    # The app's environment is already loaded here.
    Rake::Task.define_task(:environment)
    User.delete_all
    Member.delete_all
  end

  def teardown
    User.delete_all
    Member.delete_all
    Rake.application = Rake::Application.new
    super
  end

  def run_task(name, *)
    output = StringIO.new
    $stdout = output
    @rake[name].invoke(*)
    output.string
  ensure
    $stdout = STDOUT
  end

  # Rows written behind normalizes' back, as an app adopting the gem has them
  # (insert_all would normalise them).
  def seed(model, values)
    connection = model.lease_connection
    values.each_with_index do |value, index|
      connection.execute("INSERT INTO #{model.table_name} (username, email) " \
                         "VALUES (#{connection.quote(value)}, 'u#{index}@example.com')")
    end
  end

  def test_audit_reports_noncanonical_values_collisions_and_rule_failures
    seed(User, ["JAVI", "javi", " ana", "@pedro", "admin", "ok_name", nil, nil])

    output = run_task("usernames:audit", "User", "username")

    assert_match(/usernames:audit User#username \(users\.username, lowercase mode, \w+\) — read-only/, output)
    assert_match(/✗ 3 differ from their normalised form/, output)
    assert_match(/"JAVI" → "javi"/, output)
    assert_match(/" ana" → "ana"/, output)
    assert_match(/"@pedro" → "pedro"/, output)
    assert_match(/✗ groups that collide once normalised: 1/, output)
    assert_match(/"javi": #\d+ "JAVI", #\d+ "javi"/, output)
    refute_match(/nil.*nil/, output, "absent usernames are not identities and never group")
    assert_match(/· 1 fail today's rules.*\n.*"admin": username_reserved/, output)
    assert_match(/Stored values \(6 with a username\)/, output)
    assert_match(/✓ index_users_on_username matches the lowercase mode/, output)
    assert_match(/\d+ things? to fix/, output)
  end

  def test_audit_of_a_clean_column
    User.create!(username: "javi", email: "j@example.com")

    output = run_task("usernames:audit")

    assert_match(/✓ every stored username is already in its normalised form/, output)
    assert_match(/✓ no two stored names collide/, output)
    assert_match(/✓ every stored username passes today's rules/, output)
    assert_match(/Nothing to fix/, output)
  end

  def test_audit_reports_a_missing_index_in_preserve_mode
    seed(Member, %w[Javi javi])

    output = with_config(case: :preserve) { run_task("usernames:audit", "Member", "username") }

    assert_match(/preserve mode/, output)
    assert_match(/no unique index matches the preserve mode/, output)
    assert_match(/add_index :members, "lower\(username( COLLATE \\"C\\")?\)", unique: true, /, output)
    assert_match(/name: "index_members_on_lower_username"/, output)
    assert_match(/"javi": #\d+ "Javi", #\d+ "javi"/, output, "Javi and javi collide in preserve mode")
    refute_match(/differ from their normalised form:/, output, "preserve mode needs no case rewrite")
  end

  def test_audit_of_a_missing_column
    output = run_task("usernames:audit", "Player", "username")

    assert_match(/there is no column players\.username/, output)
    assert_match(/1 thing to fix/, output)
  end

  def test_audit_returns_the_problem_count_and_never_writes
    seed(User, %w[JAVI])

    assert_no_difference = User.pluck(:username)
    problems = Usernames::Audit.new("User").report(StringIO.new)

    assert_equal 1, problems
    assert_equal assert_no_difference, User.pluck(:username)
  end

  def test_audit_lists_at_most_twenty_examples
    seed(Member, Array.new(25) { |index| "USER#{index}" })

    output = run_task("usernames:audit", "Member", "username")

    assert_match(/✗ 25 differ/, output)
    assert_match(/… and 5 more/, output)
  end

  def test_audit_column_criteria_per_adapter
    audit = Usernames::Audit.new(User)
    output = StringIO.new
    audit.instance_variable_set(:@io, output)

    audit.send(:sqlite_column, "varchar", "NOCASE")
    audit.send(:expect_collation, "varchar(255)", "utf8mb4_0900_ai_ci", "utf8mb4_bin")
    audit.send(:expect_collation, "varchar(255)", "utf8mb4_bin", "utf8mb4_bin")
    audit.stub(:deterministic?, false) do
      audit.send(:postgresql_column, "citext", nil)
      audit.send(:postgresql_column, "character varying", "tr-x-icu")
      audit.send(:postgresql_column, "integer", "C")
    end

    assert_match(/COLLATE NOCASE: the contract is SQLite's default BINARY/, output.string)
    assert_match(/collation "utf8mb4_0900_ai_ci": set collation: "utf8mb4_bin"/, output.string)
    assert_match(/✓ varchar\(255\), collation utf8mb4_bin/, output.string)
    assert_match(/citext is incompatible/, output.string)
    assert_match(/collation "tr-x-icu": equality and lower\(\) follow it/, output.string)
    assert_match(/nondeterministic/, output.string)
    assert_match(/integer is not text or character varying/, output.string)
  end

  def test_audit_of_an_unknown_model_aborts
    assert_raises(SystemExit) { capture_io { run_task("usernames:audit", "Nope") } }
  end

  def test_reserved_lists_every_word_with_its_source
    lists = { reserved: Usernames::Data.reserved + %w[festival], forbidden: Usernames::Data.impersonation + %w[yourapp],
              allowed: %w[help] }
    output = with_config(**lists) do
      run_task("usernames:reserved")
    end

    assert_match(/\A\d+ reserved names/, output)
    assert_match(/^  admin +impersonation · /, output)
    assert_match(/^  festival +config\.reserved$/, output)
    assert_match(/^  yourapp +config\.forbidden$/, output)
    assert_match(/^  login +\w+ · \S+ \(/, output)
    refute_match(/^  help /, output)
    assert_match(/Lifted by config\.allowed: help/, output)
  end

  def test_reserved_marks_routes
    Usernames::Reserved.stub(:routes, Set["festivals"]) do
      assert_match(%r{^  festivals +route /festivals$}, run_task("usernames:reserved"))
    end
  end

  def test_reserved_for_one_model
    output = run_task("usernames:reserved", "Player", "handle")

    assert_match(/reserved names/, output)
    assert_raises(SystemExit) do
      capture_io do
        @rake["usernames:reserved"].reenable || run_task("usernames:reserved", "Nope")
      end
    end
  end

  def test_reserved_listing_entries
    entries = Usernames::Reserved::Listing.entries.to_h

    assert_equal entries.keys.sort, entries.keys
    assert(entries.keys.none? { |word| word != word.downcase })
    assert_operator entries.size, :>, 1000
  end
end
