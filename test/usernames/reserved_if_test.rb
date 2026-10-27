# frozen_string_literal: true

require "test_helper"

# config.reserved_if: names reserved by the app's own data, asked after
# every word list.
class ReservedIfTest < UsernamesTestCase
  PAGES = %w[about_us summer_sale CoolPage].freeze

  def page?
    ->(name) { PAGES.include?(name) }
  end

  def test_nil_by_default
    assert_nil Usernames.configuration.reserved_if
    assert_nil Usernames.configuration.rules_for.reserved_if
    assert_predicate Usernames.check("summer_sale"), :ok?
  end

  def test_a_truthy_answer_reserves_the_name
    with_config(reserved_if: page?) do
      result = Usernames.check("summer_sale")

      assert_equal :username_reserved, result.reason
      assert_equal :reserved_if, result.rule
      assert_equal "is reserved", result.message
      assert_predicate Usernames.check("winter_sale"), :ok?
    end
  end

  # The name as normalised: pasted @ and case gone in lowercase mode, case
  # kept in preserve mode.
  def test_it_receives_the_normalised_name
    asked = []
    with_config(reserved_if: ->(name) { (asked << name) && false }) do
      Usernames.check(" @Summer_Sale ")
      Usernames.check("CoolPage", case: :preserve)
    end

    assert_equal %w[summer_sale CoolPage], asked
  end

  def test_it_is_not_asked_when_a_list_already_decides
    asked = []
    with_config(reserved_if: ->(name) { (asked << name) && true }, allowed: %w[helpdesk]) do
      assert_equal :impersonation, Usernames.check("admin").rule
      assert_equal :exact, Usernames.check("login").rule
      assert_predicate Usernames.check("helpdesk"), :ok?, "config.allowed lifts it too"
      assert_equal :username_edges, Usernames.check("_x_y").reason, "nor for a name that breaks a format rule"
      Usernames::Reserved.stub(:routes, Set["recipes"]) { assert_equal :route, Usernames.check("recipes").rule }
    end

    assert_empty asked
  end

  def test_a_model_refuses_it_and_the_availability_answer_is_taken
    with_config(reserved_if: page?) do
      user = User.new(username: "about_us", email: "a@example.com")

      refute_predicate user, :valid?
      assert_equal [{ error: :username_reserved }], user.errors.details[:username]
      refute User.username_available?("about_us")
    end
  end

  def test_per_model
    model = Class.new(ApplicationRecord) do
      self.table_name = "users"
      has_username reserved_if: ->(name) { name.start_with?("club_") }
    end

    refute_predicate model.new(username: "club_red"), :valid?
    assert_predicate User.new(username: "club_red", email: "t@example.com"), :valid?
  end

  def test_its_errors_are_the_apps
    with_config(reserved_if: ->(_name) { raise ArgumentError, "the app's bug" }) do
      error = assert_raises(ArgumentError) { Usernames.check("summer_sale") }

      assert_equal "the app's bug", error.message
    end
  end

  def test_it_must_answer_call
    Usernames.configuration.reserved_if = "Page.exists?"
    error = assert_raises(Usernames::ConfigurationError) { Usernames.configuration.validate! }

    assert_equal 'reserved_if must be nil or a callable such as ->(name) { … } (got "Page.exists?")', error.message
  end
end
