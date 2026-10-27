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
    @rake[name].reenable
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
    assert_match(/\A\d+ things? to fix\. /, output.lines.last, "the last line says how many, for a script to grep")
  end

  def test_audit_of_a_clean_column
    User.create!(username: "javi", email: "j@example.com")

    output = run_task("usernames:audit")

    assert_match(/✓ every stored username is already in its normalised form/, output)
    assert_match(/✓ no two stored names collide/, output)
    assert_match(/✓ every stored username passes today's rules/, output)
    assert_match(/\ANothing to fix: /, output.lines.last)
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

  # A unique index is not uniqueness when it covers only some rows, or
  # compares under a collation of its own: the audit says so, index by index.
  def test_audit_refuses_indexes_that_do_not_enforce_the_contract
    connection = Member.lease_connection
    connection.add_index :members, :username, unique: true, where: "email IS NOT NULL", name: "members_partial"
    connection.add_index :members, "username COLLATE #{POSTGRESQL ? '"und-x-icu"' : 'NOCASE'}", unique: true,
                                                                                                name: "members_nocase"

    output = run_task("usernames:audit", "Member", "username")

    assert_match(/· members_partial \(unique on username\) — only covers rows WHERE \(?email IS NOT NULL\)?/, output)
    assert_match(/· members_nocase \(unique on username\) — compares under collation "(NOCASE|und-x-icu)"/, output)
    assert_match(/✗ no unique index matches the lowercase mode/, output)
    refute_match(/Nothing to fix/, output)
  ensure
    %w[members_partial members_nocase].each { |name| connection.remove_index :members, name: name, if_exists: true }
  end

  # The adoption workflow audits before has_username is declared: the model
  # cannot say its mode then, so the task takes it, and says what it assumed.
  def test_audit_of_an_undeclared_column_takes_the_case_mode
    seed(Member, %w[Javi javi])

    assumed = run_task("usernames:audit", "Member", "username")
    told = run_task("usernames:audit", "Member", "username", "preserve")

    assert_match(/lowercase mode/, assumed)
    assert_match(/Member doesn't declare has_username :username yet: checked against the configured rules/, assumed)
    assert_match(/in lowercase mode \(the configured one; for preserve: usernames:audit\[Member,username,preserve\]\)/,
                 assumed)
    assert_match(/"Javi" → "javi"/, assumed)
    assert_match(/preserve mode/, told)
    assert_match(/in preserve mode\n/, told)
    assert_match(/no unique index matches the preserve mode/, told)
    refute_match(/differ from their normalised form:/, told)
  end

  def test_audit_of_a_declared_column_says_nothing_about_declaring
    refute_match(/doesn't declare/, run_task("usernames:audit"))
  end

  def test_audit_refuses_an_unknown_case_mode
    assert_raises(SystemExit) { capture_io { run_task("usernames:audit", "Member", "username", "upper") } }
    assert_raises(ArgumentError) { Usernames::Audit.new(Member, :username, mode: :upper) }
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

  # In preserve mode the expression carries COLLATE "C", so a locale (or even
  # nondeterministic) column collation is not a problem — only citext is.
  def test_audit_in_preserve_mode_accepts_any_postgresql_collation
    audit = Usernames::Audit.new(Player, :handle)
    output = StringIO.new
    audit.instance_variable_set(:@io, output)

    audit.stub(:deterministic?, false) do
      audit.send(:postgresql_column, "character varying", "en_US.UTF-8")
      audit.send(:postgresql_column, "citext", nil)
    end

    assert_match(/✓ character varying, collation "en_US.UTF-8" \(compared through COLLATE "C"\)/, output.string)
    assert_match(/citext is incompatible/, output.string)
    refute_match(/nondeterministic|set collation/, output.string)
  end

  def test_audit_of_an_unknown_model_aborts
    assert_raises(SystemExit) { capture_io { run_task("usernames:audit", "Nope") } }
  end

  def test_reserved_lists_every_word_with_its_source
    lists = { reserved: Usernames::Data.reserved + %w[recipe], forbidden: Usernames::Data.impersonation + %w[yourapp],
              allowed: %w[help] }
    output = with_config(**lists) do
      run_task("usernames:reserved")
    end

    assert_match(/\A\d+ reserved names/, output)
    assert_match(/^  admin +impersonation · /, output)
    assert_match(/^  recipe +config\.reserved$/, output)
    assert_match(/^  yourapp +config\.forbidden$/, output)
    assert_match(/^  login +\w+ · \S+ \(/, output)
    refute_match(/^  help /, output)
    assert_match(/Lifted by config\.allowed: help/, output)
  end

  def test_reserved_names_config_reserved_if
    refute_match(/reserved_if/, run_task("usernames:reserved"))

    output = with_config(reserved_if: ->(_name) { false }) { run_task("usernames:reserved") }

    assert_match(/^And whatever config\.reserved_if reserves, asked after these lists\.$/, output)
  end

  def test_reserved_marks_routes
    Usernames::Reserved.stub(:routes, Set["recipes"]) do
      assert_match(%r{^  recipes +route /recipes$}, run_task("usernames:reserved"))
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
