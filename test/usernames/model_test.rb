# frozen_string_literal: true

require "test_helper"

# A name nobody else gets to choose for you: neither generated nor required.
class HandpickedUser < ApplicationRecord
  self.table_name = "users"
  has_username generate: false
end

# A User whose competitor can be made to arrive in the race window — after
# validation said the name was free, before the INSERT or UPDATE reaches the
# unique index. That window is the race, reproduced without timing luck.
# (SQLite's shared cache cannot hold two write transactions at once, so the
# two-thread races run in pg_test.rb.)
class RacingUser < ApplicationRecord
  self.table_name = "users"
  has_username

  # `rival` arrives once, after validation (outside the savepoint, so its row
  # stays); `competitor` arrives on every attempt, in before_create /
  # before_update, inside the savepoint.
  cattr_accessor :rival
  cattr_accessor :competitor
  cattr_accessor :before_create_calls, default: 0
  cattr_accessor :after_create_calls, default: 0
  cattr_accessor :before_save_calls, default: 0

  before_save { self.class.before_save_calls += 1 }
  before_create { self.class.before_create_calls += 1 }
  after_create { self.class.after_create_calls += 1 }
  after_validation { rival&.call(self) }
  before_create { competitor&.call(self) }
  before_update { competitor&.call(self) }
end

# has_username declared once, on an abstract parent: the concrete class has the table.
class NamedRecord < ApplicationRecord
  self.abstract_class = true
  has_username case: :preserve
end

class InheritedUser < NamedRecord
  self.table_name = "users"
end

# Single-table inheritance: a staff persona and a persona share one name space.
class Persona < ApplicationRecord
  has_username :handle, case: :preserve
end

class StaffPersona < Persona; end

class ModelTest < UsernamesTestCase
  def setup
    super
    User.delete_all
    Player.delete_all
    RacingUser.rival = nil
    RacingUser.competitor = nil
    RacingUser.before_create_calls = 0
    RacingUser.after_create_calls = 0
    RacingUser.before_save_calls = 0
  end

  # Another person taking `name` from under the record's feet.
  def take(name, email: "rival-#{SecureRandom.hex(4)}@example.com")
    User.insert_all([{ username: name, email: email }])
  end

  # Statements sent to the database, not counting schema reads or
  # transaction control.
  def count_queries(&)
    count = 0
    counter = lambda do |*, payload|
      count += 1 unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name]) ||
                        payload[:sql].match?(/\A\s*(SAVEPOINT|RELEASE|ROLLBACK|BEGIN|COMMIT)/i)
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    count
  end

  # --- what has_username installs (PRD §6.1) ------------------------------------------------------

  def test_normalizes_on_assignment
    user = User.new(username: "  @Javi_R ")

    assert_equal "javi_r", user.username
    assert_nil User.new(username: "   ").username
  end

  def test_validates_with_the_rules
    user = User.new(username: "Ad_min2", email: "a@example.com")

    refute_predicate user, :valid?
    assert_equal [{ error: :username_reserved }], user.errors.details[:username]
    assert_equal ["Username is reserved"], user.errors.full_messages
  end

  def test_uniqueness_on_create_and_update
    User.create!(username: "javi", email: "j@example.com")
    other = User.create!(username: "ana", email: "a@example.com")

    refute_predicate User.new(username: "JAVI", email: "x@example.com"), :valid?
    other.username = "javi"

    refute_predicate other, :valid?
    assert_equal :taken, other.errors.details[:username].first[:error]
  end

  def test_declaring_a_column_twice_is_a_configuration_error
    error = assert_raises(Usernames::ConfigurationError) do
      Class.new(ApplicationRecord) do
        self.table_name = "users"
        has_username
        has_username
      end
    end

    assert_match(/has_username :username is already declared/, error.message)
  end

  def test_bad_options_fail_when_the_model_is_defined
    assert_raises(Usernames::ConfigurationError) { Class.new(ApplicationRecord) { has_username length: 3 } }
    error = assert_raises(Usernames::ConfigurationError) { Class.new(ApplicationRecord) { has_username required: "yes" } }

    assert_match(/required: must be true or false/, error.message)
  end

  # --- the required × generate matrix (PRD §6.1), on create and update ---------------------------

  def test_default_generates_on_create
    user = User.create!(email: "ana@example.com")

    assert_predicate user.username, :present?
    assert_predicate Usernames.check(user.username), :ok?
    assert_predicate user, :username_generated?
  end

  def test_default_on_update_a_legacy_nil_saves_and_blank_stores_nil
    take(nil, email: "legacy@example.com")
    legacy = User.find_by!(email: "legacy@example.com")

    assert legacy.update(name: "Legacy")
    assert_nil legacy.reload.username

    named = User.create!(username: "javi", email: "j@example.com")

    assert named.update(username: "  ")
    assert_nil named.reload.username
  end

  def test_generate_false_leaves_it_blank_on_create_and_update
    user = HandpickedUser.create!(email: "h@example.com")

    assert_nil user.username
    refute_predicate user, :username_generated?
    assert user.update(name: "H")
    user.update!(username: "handpicked")

    assert user.update(username: "")
    assert_nil user.reload.username
  end

  def test_required_is_blank_on_create_and_never_generates
    user = StrictUser.new(email: "s@example.com")

    refute_predicate user, :valid?
    assert_equal [{ error: :blank }], user.errors.details[:username]
    assert_nil user.username
    refute(StrictUser._validation_callbacks.any? { |callback| callback.filter == :assign_username })
    assert(User._validation_callbacks.any? { |callback| callback.filter == :assign_username })
  end

  def test_required_lets_a_legacy_nil_save_but_not_a_clearing
    take(nil, email: "legacy@example.com")
    legacy = StrictUser.find_by!(email: "legacy@example.com")

    assert legacy.update(name: "Unrelated")

    named = StrictUser.create!(username: "javi", email: "j@example.com")

    refute named.update(username: "")
    assert_equal [{ error: :blank }], named.errors.details[:username]
  end

  # --- validate only on change (D-11) --------------------------------------------------------------

  def test_a_now_reserved_legacy_name_saves_other_attributes
    take("admin", email: "old@example.com")
    legacy = User.find_by!(email: "old@example.com")

    assert legacy.update(name: "Grandfathered")
    legacy.username = "admin2"

    refute_predicate legacy, :valid?
  end

  # --- generation ----------------------------------------------------------------------------------

  def test_a_given_name_is_not_generated
    user = User.create!(username: "javi", email: "j@example.com")

    refute_predicate user, :username_generated?
  end

  def test_generated_stops_being_true_once_the_name_is_changed
    user = User.create!(email: "g@example.com")
    user.username = "chosen"

    refute_predicate user, :username_generated?
  end

  # --- races (PRD §11.3) -----------------------------------------------------------------------------

  def test_a_generated_name_taken_in_the_race_window_is_redrawn
    RacingUser.rival = ->(record) { take(record.username) }

    user = RacingUser.create!(email: "r@example.com")

    assert_predicate user, :persisted?
    assert_predicate user, :username_generated?
    assert_equal 2, User.count
    assert_equal 2, RacingUser.before_create_calls, "before_create runs once per attempt"
    assert_equal 1, RacingUser.after_create_calls, "after_create runs once, for the attempt that succeeded"
    assert_equal 1, RacingUser.before_save_calls, "before_save wraps every attempt: it runs once"
  end

  def test_redraws_stop_after_three_then_taken
    RacingUser.competitor = ->(record) { take(record.username) }
    draws = 0
    generate = RacingUser.method(:generate_username)
    user = RacingUser.new(email: "r@example.com")

    RacingUser.stub(:generate_username, lambda { |**options|
      draws += 1
      generate.call(**options)
    }) do
      refute user.save
    end

    assert_equal 4, draws, "the name on create, then three redraws"
    assert_equal 4, RacingUser.before_create_calls
    assert_equal [{ error: :taken }], user.errors.details[:username]
    assert_predicate user, :new_record?
    assert_nil user.id
  end

  def test_a_typed_name_lost_in_a_create_race_is_taken
    RacingUser.competitor = ->(record) { take(record.username) }
    user = RacingUser.new(username: "javi", email: "r@example.com")

    refute user.save
    assert_equal [{ error: :taken }], user.errors.details[:username]
    assert_equal "javi", user.username, "a typed name is never replaced"

    error = assert_raises(ActiveRecord::RecordInvalid) { RacingUser.new(username: "ana", email: "s@example.com").save! }

    assert_equal ["Username has already been taken"], error.record.errors.full_messages
  end

  def test_a_typed_name_lost_in_an_update_race_is_taken
    user = RacingUser.create!(username: "javi", email: "r@example.com")
    RacingUser.competitor = ->(record) { take(record.username) }

    refute user.update(username: "javier")
    assert_equal [{ error: :taken }], user.errors.details[:username]
    assert_raises(ActiveRecord::RecordInvalid) { user.update!(username: "javiera") }
    assert_equal "javi", user.reload.username
  end

  def test_an_update_that_does_not_touch_the_name_is_not_wrapped
    user = RacingUser.create!(username: "javi", email: "r@example.com")
    take("other", email: "taken@example.com")

    error = assert_raises(ActiveRecord::RecordNotUnique) { user.update(email: "taken@example.com") }

    assert_match(/email/, error.message)
  end

  def test_an_unrelated_unique_violation_propagates
    take("someone", email: "dup@example.com")

    assert_raises(ActiveRecord::RecordNotUnique) { User.create(username: "javi", email: "dup@example.com") }
    assert_raises(ActiveRecord::RecordNotUnique) { User.create(email: "dup@example.com") }
  end

  def test_unique_violation_is_asked_which_index_failed
    RacingUser.competitor = ->(record) { take(record.username) }

    Usernames::UniqueViolation.stub(:of?, false) do
      assert_raises(ActiveRecord::RecordNotUnique) { RacingUser.create(username: "javi", email: "r@example.com") }
    end
  end

  def test_surrounding_writes_survive_a_redraw
    RacingUser.rival = ->(record) { take(record.username) }

    ActiveRecord::Base.transaction do
      User.create!(username: "before", email: "before@example.com")
      RacingUser.create!(email: "r@example.com")
      User.create!(username: "after", email: "after@example.com")
    end

    assert_equal %w[after before], User.where(username: %w[before after]).order(:username).pluck(:username)
    assert_equal 4, User.count, "both outer rows, the rival and the redrawn user"
  end

  def test_a_lost_typed_race_inside_an_outer_transaction_keeps_the_outer_writes
    ActiveRecord::Base.transaction do
      User.create!(username: "kept", email: "kept@example.com")
      RacingUser.competitor = ->(record) { take(record.username) }

      refute RacingUser.new(username: "javi", email: "r@example.com").save
    end

    assert User.exists?(username: "kept")
  end

  # --- class helpers -------------------------------------------------------------------------------

  def test_find_by_username_normalizes
    User.create!(username: "javi", email: "j@example.com")

    assert_equal "javi", User.find_by_username("@Javi")&.username
    assert_equal "javi", User.find_by_username(" JAVI ")&.username
    assert_nil User.find_by_username("   ")
    assert_nil User.find_by_username("nobody")
  end

  def test_username_available
    User.create!(username: "javi", email: "j@example.com")

    refute User.username_available?("javi"), "taken"
    refute User.username_available?("@JAVI"), "taken, once normalised"
    refute User.username_available?("admin"), "reserved"
    refute User.username_available?("shithead"), "offensive"
    refute User.username_available?("_ana"), "invalid"
    refute User.username_available?(""), "blank"
    assert User.username_available?("ana")
  end

  def test_suggest_usernames_is_one_query_and_skips_taken_names
    User.create!(username: "javi_r", email: "j@example.com")
    suggestions = nil

    assert_equal(1, count_queries { suggestions = User.suggest_usernames("Javi R", count: 5) })
    assert_equal 5, suggestions.size
    refute_includes suggestions, "javi_r"
    assert_equal "javir", suggestions.first
    assert(suggestions.all? { |name| Usernames.allowed?(name) })
  end

  def test_suggest_usernames_may_return_fewer
    Usernames::Candidates.stub(:for, %w[javi ana]) do
      User.create!(username: "javi", email: "j@example.com")

      assert_equal %w[ana], User.suggest_usernames("javi", count: 5)
    end
    Usernames::Candidates.stub(:for, []) do
      assert_equal(0, count_queries { assert_empty User.suggest_usernames("javi") })
    end
  end

  def test_generate_username_is_one_query
    name = nil

    assert_equal(1, count_queries { name = User.generate_username })
    assert_predicate Usernames.check(name), :ok?
    assert_equal "jose_garcia", User.generate_username(from: "José García")
  end

  def test_generate_username_from_a_taken_seed_moves_on
    User.create!(username: "pedro_gonzales_armillon", email: "p@example.com")

    assert_match(/\Apedro_gonzales_armillon_\d{2}\z|\Apedro_gonzales_\d{2,3}\z/,
                 User.generate_username(from: "Pedro Gonzales Armillon"))
  end

  def test_generate_username_raises_when_the_batch_is_all_taken
    Usernames::Generator.stub(:candidates, %w[javi]) do
      User.create!(username: "javi", email: "j@example.com")

      error = assert_raises(Usernames::NoFreeNameError) { User.generate_username }
      assert_match(/every generated username in this batch is taken/, error.message)
    end
  end

  def test_username_options_are_the_columns_rules
    assert_equal({ case: :lowercase }, User.username_options)
    assert_equal({ length: 2..24, case: :preserve, separators: %w[_ . -] }, Player.handle_options)
  end

  # The model's error, the pure check and the browser hints say one thing,
  # and a per-model translation is that thing on all three.
  def test_check_and_browser_rules_speak_in_the_models_words
    I18n.backend.store_translations(:en, activerecord: { errors: { models: { player: { attributes: { handle: {
                                      username_edges: "starts and ends with a letter or number",
                                      too_short: { one: "one at least", other: "%{count} at least" }
                                    } } } } } })

    result = Player.check_handle(" _Javi ")

    assert_equal [false, :username_edges, "_Javi"], [result.ok?, result.reason, result.canonical]
    assert_equal "starts and ends with a letter or number", result.message
    assert_equal [result.message], Player.new(handle: "_Javi").tap(&:validate).errors[:handle]
    assert_equal "2 at least", Player.check_handle("J").message
    hints = Player.handle_rules_for_browser.to_h { |rule| [rule[:rule], rule[:message]] }

    assert_equal "starts and ends with a letter or number", hints[:username_edges]
    assert_equal "2 at least", hints[:too_short]
    patterns = [Usernames.rules_for_browser(**Player.handle_options), Player.handle_rules_for_browser].map do |rules|
      rules.map { |rule| rule[:pattern] }
    end

    assert_equal patterns.first, patterns.last
    assert_equal "can't start or end with an underscore, a period or a dash",
                 Usernames.check("_Javi", **Player.handle_options).message, "the global check keeps the gem's words"
  ensure
    I18n.backend.reload!
  end

  def test_check_is_eligibility_only
    Player.create!(handle: "Javi")

    assert_predicate Player.check_handle("javi"), :ok?, "taken is availability, not eligibility"
    assert_equal :username_reserved, Player.check_handle("admin").reason
    assert_nil Player.check_handle("javi").message
  end

  def test_the_case_mode_is_pinned_when_the_model_is_declared
    with_config(case: :preserve) do
      assert_equal "javi", User.new(username: "Javi").username
    end
  end

  # --- a renamed column, kept case (Player#handle) ----------------------------------------------------

  def test_helpers_are_named_after_the_column
    %i[handle_available? suggest_handles generate_handle find_by_handle handle_options check_handle
       handle_rules_for_browser].each do |helper|
      assert_respond_to Player, helper
    end
    refute_respond_to Player, :suggest_usernames
    assert_respond_to Player.new, :handle_generated?
  end

  def test_preserve_mode_keeps_case_and_compares_without_it
    Player.create!(handle: "Javi")

    assert_equal "Javi", Player.find_by_handle("@javi")&.handle
    duplicate = Player.new(handle: "javi")

    refute_predicate duplicate, :valid?
    assert_equal :taken, duplicate.errors.details[:handle].first[:error]
    refute Player.handle_available?("JAVI")
  end

  def test_preserve_mode_allows_a_case_only_change_of_ones_own_name
    player = Player.create!(handle: "Javi")

    assert player.update(handle: "JAVI")
    assert_equal "JAVI", player.reload.handle
  end

  def test_preserve_mode_rules_are_the_models
    assert Player.handle_available?("j.r")
    refute User.username_available?("j.r")
    assert_predicate Player.new(handle: "Jo-Ann"), :valid?
  end

  def test_preserve_mode_suggestions_and_generation
    Player.create!(handle: "Javi")
    suggestions = Player.suggest_handles("javi", count: 3)

    assert_equal 3, suggestions.size
    refute(suggestions.any? { |name| name.casecmp?("javi") })
    assert_predicate Player.generate_handle, :present?
    assert_predicate Player.create!, :handle_generated?
  end

  def test_preserve_mode_race_is_taken
    player = Player.new(handle: "Racer")
    Player.insert_all([{ handle: "RACER" }])

    # The uniqueness check has already looked, and found it free.
    def player.valid?(*) = true

    refute player.save
    assert_equal [{ error: :taken }], player.errors.details[:handle]
  end

  # --- running out of generated names ---------------------------------------------------------------

  # generate_username raises; a save that needs a generated name fails like
  # a validation instead, and asks the person to choose.
  def test_a_new_record_with_no_free_generated_name_is_invalid
    take("only_candidate")
    with_config(generator: ->(_attempt) { "only_candidate" }) do
      user = User.new(email: "n@example.com")

      refute user.save
      assert_equal [{ error: :username_unavailable }], user.errors.details[:username]
      assert_equal ["Username couldn't be assigned automatically, please choose one"], user.errors.full_messages
      assert_raises(ActiveRecord::RecordInvalid) { User.create!(email: "o@example.com") }
      assert_raises(Usernames::NoFreeNameError) { User.generate_username }
    end
  end

  def test_running_out_while_redrawing_is_invalid_too
    with_config(generator: ->(_attempt) { "only_candidate" }) do
      RacingUser.rival = ->(record) { take(record.username) }
      user = RacingUser.new(email: "r@example.com")

      refute user.save
      assert_equal [{ error: :username_unavailable }], user.errors.details[:username]
      assert_predicate user, :new_record?
      assert_equal 1, RacingUser.before_create_calls, "the insert was tried, then the redraw ran out"

      User.where(username: "only_candidate").delete_all
      error = assert_raises(ActiveRecord::RecordInvalid) { RacingUser.create!(email: "s@example.com") }

      assert_equal [{ error: :username_unavailable }], error.record.errors.details[:username]
    end
  end

  # --- one error per name ---------------------------------------------------------------------------

  # A legacy `admin` is still in the table: a new `admin` is reserved, not
  # also taken.
  def test_a_name_that_breaks_a_rule_is_not_also_taken
    take("admin")
    Player.insert_all([{ handle: "Admin" }])

    assert_equal({ username: [{ error: :username_reserved }] },
                 User.new(username: "admin").tap(&:validate).errors.details)
    assert_equal [{ error: :username_reserved }], Player.new(handle: "ADMIN").tap(&:validate).errors.details[:handle]
    assert_equal [{ error: :taken, value: "javi" }],
                 User.new(username: "javi").tap { take("javi") }.tap(&:validate).errors.details[:username]
  end

  # --- inheritance ----------------------------------------------------------------------------------

  def test_has_username_inherited_from_an_abstract_parent
    take("javi")

    assert_equal [{ error: :taken, value: "Javi" }],
                 InheritedUser.new(username: "Javi").tap(&:validate).errors.details[:username]
    assert_predicate InheritedUser.new(username: "Ana", email: "a@example.com"), :valid?
    assert InheritedUser.username_available?("ana")
    refute InheritedUser.username_available?("JAVI")
  end

  def test_single_table_inheritance_shares_one_name_space
    Persona.delete_all
    Persona.create!(handle: "Javi")

    assert_equal [{ error: :taken, value: "JAVI" }],
                 StaffPersona.new(handle: "JAVI").tap(&:validate).errors.details[:handle]
    staff = StaffPersona.create!(handle: "Ana")

    assert_equal [{ error: :taken, value: "ana" }], Persona.new(handle: "ana").tap(&:validate).errors.details[:handle]
    assert staff.update(handle: "ANA"), "a case-only change of one's own name"
    refute StaffPersona.handle_available?("javi")
  ensure
    Persona.delete_all
  end
end
