# frozen_string_literal: true

require "test_helper"

class ReservedRoutesController < ActionController::Base; end

module RecipeBox
  # Stands in for a Rails application: the app name comes from the module
  # its Application class is defined in.
  class Application
    def routes
      @routes ||= ActionDispatch::Routing::RouteSet.new.tap do |routes|
        routes.draw { get "lineup", to: "reserved_routes#show" }
      end
    end
  end
end

# Reserved names (PRD §9): exact and impersonation matching, the prefixes,
# config.allowed, the app's own name and its routes.
class ReservedTest < UsernamesTestCase
  DOTS = { separators: %w[_ .] }.freeze

  def teardown
    super
    Usernames::Reserved.reset_routes!
  end

  def rule(name, **)
    result = Usernames.check(name, **DOTS, **)
    result.rule if result.reason == :username_reserved
  end

  def verdict(key, **)
    Usernames::Reserved.verdict(key, Usernames.configuration.rules_for(**))
  end

  # PRD §9.2, required behaviour.
  def test_impersonation_is_matched_in_every_form_it_is_typed
    %w[admin2 ad.min adm1n admin_bob adm1n_bob admin1bob admin2bob bob.support official_javi admins].each do |name|
      assert_equal :impersonation, rule(name), name
    end
  end

  def test_impersonation_is_never_a_prefix_or_suffix_and_exact_words_fold_nothing
    %w[supportive staffordshire teamwork adminbob GAME969 badminton_fan].each do |name|
      assert_predicate Usernames.check(name, **DOTS), :ok?, name
    end
  end

  def test_the_example_of_the_readme
    result = Usernames.check("Ad_min")

    assert_equal [false, :username_reserved, :impersonation, "ad_min", "is reserved"],
                 [result.ok?, result.reason, result.rule, result.canonical, result.message]
  end

  def test_leet_folding_is_symmetric_and_a_literal_custom_entry_forbids_itself
    with_config(forbidden: ["web3"]) do
      refute Usernames.allowed?("web3")
      refute Usernames.allowed?("w3b3")
      refute Usernames.allowed?("webe")
      assert Usernames.allowed?("web3x")
      # `=` replaced the bundled words.
      assert Usernames.allowed?("moderator")
    end
  end

  def test_custom_forbidden_words_add_to_the_bundled_ones_and_take_plurals
    assert_equal :impersonation, rule("yourapps", forbidden: %w[yourapp])
    assert_equal :impersonation, rule("yourapp_help", forbidden: %w[yourapp])
    assert_equal :impersonation, rule("admin", forbidden: %w[yourapp])
  end

  def test_an_entry_with_separators_also_matches_without_them
    assert_equal :impersonation, rule("myapp", forbidden: %w[my_app])
    assert_equal :impersonation, rule("my.app", forbidden: %w[my_app])
  end

  def test_exact_words_are_matched_exactly
    %w[null undefined everyone anon login dashboard settings info].each do |name|
      assert_equal :exact, rule(name), name
    end
    %w[null1 everyone2 login_page settingsx].each do |name|
      assert_predicate Usernames.check(name), :ok?, name
    end
  end

  def test_config_reserved_words_are_custom_and_replacing_drops_the_bundled_ones
    assert_equal :custom, rule("recipe", reserved: %w[recipe])
    assert_equal :custom, rule("Recipe", reserved: %w[RECIPE], case: :preserve)

    with_config(reserved: %w[recipe]) do
      assert_equal :custom, rule("recipe")
      assert Usernames.allowed?("dashboard")
    end
  end

  def test_well_known_and_punycode_prefixes
    assert_equal :exact, verdict(".well-known")
    assert_equal :exact, verdict(".well-known-thing")
    assert_equal :exact, verdict("xn--80ak6aa92e")
    refute_predicate Usernames.check("xn--80ak6aa92e", separators: %w[-]), :ok?
    assert_nil verdict("wellknown")
  end

  def test_allowed_lifts_a_verdict_for_exactly_that_name
    assert Usernames.allowed?("admin", allowed: %w[admin])
    assert Usernames.allowed?("null", allowed: %w[NULL])
    refute Usernames.allowed?("admin_bob", allowed: %w[admin])
    assert_nil verdict(".well-known", allowed: %w[.well-known])
  end

  def test_allowed_never_lifts_an_offensive_verdict
    refute Usernames.allowed?("shithead", allowed: %w[shithead])
  end

  def test_app_name_from_config
    with_config(app_name: "RecipeBox") do
      %w[recipe_box recipebox recipeboxs recipebox_bob r3cipebox].each do |name|
        assert_equal :impersonation, rule(name), name
      end
      assert Usernames.allowed?("recipe")
    end
    assert_equal %w[my_app myapp], Usernames::Reserved.app_names(Usernames.configuration.rules_for(app_name: "My App!"))
  end

  def test_app_name_detected_from_the_rails_application
    Rails.stub(:application, RecipeBox::Application.new) do
      assert_equal :impersonation, rule("recipe_box")
      assert_equal :impersonation, rule("recipebox_official")
      assert Usernames.allowed?("recipe_box", app_name: false)
      assert Usernames.allowed?("javi")
    end
  end

  def test_an_application_without_a_namespace_has_no_name
    assert_equal [], Usernames::Reserved.app_names(Usernames.configuration.rules_for)
    assert_equal [], Usernames::Reserved.app_names(Usernames.configuration.rules_for(app_name: false))
  end

  def test_routes_are_collected_from_the_journey_ast
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw do
      get "login", to: "reserved_routes#show"
      get "foo/:id", to: "reserved_routes#show"
      get ":username", to: "reserved_routes#show"
      get "*path", to: "reserved_routes#show"
      get "report.:kind", to: "reserved_routes#show"
      get "@:username", to: "reserved_routes#show"
      get "Lineup", to: "reserved_routes#show"
      get "sign-up/now", to: "reserved_routes#show"
      get "archive(/:year)", to: "reserved_routes#show"
      get "draft(:id)", to: "reserved_routes#show"
      get "~tilde", to: "reserved_routes#show"
      root to: "reserved_routes#show"
      resources :posts
      mount Usernames::Engine => "/tools"
    end

    collected = Usernames::Reserved::Routes.collect(routes)

    assert_equal %w[archive foo lineup login posts sign-up tools], collected.sort
    assert_predicate collected, :frozen?
  end

  def test_routes_reserve_names_unless_turned_off
    Usernames::Reserved.stub(:routes, Set["lineup"]) do
      assert_equal :route, rule("lineup")
      assert Usernames.allowed?("lineup", reserve_routes: false)
      assert Usernames.allowed?("lineup", allowed: %w[lineup])
      assert Usernames.allowed?("lineup_bob")
    end
  end

  def test_the_rails_routes_are_memoised_until_reset
    Usernames::Reserved.reset_routes!
    Rails.stub(:application, RecipeBox::Application.new) do
      first = Usernames::Reserved.routes

      assert_equal Set["lineup"], first
      assert_same first, Usernames::Reserved.routes
      Usernames::Reserved.reset_routes!

      refute_same first, Usernames::Reserved.routes
    end
  end

  def test_no_routes_without_a_rails_application
    Usernames::Reserved.reset_routes!

    Rails.stub(:application, nil) do
      assert_empty Usernames::Reserved.routes
    end
  end

  def test_source_of_a_bundled_word
    admin = Usernames::Reserved.source_of("Admin")

    assert_equal :impersonation, admin.category
    assert_equal "usernames", admin.source
    assert_equal "MIT", admin.licence
    assert_match(/staff and authority roles/, admin.reason)

    assert_equal(%i[web gitlab], Usernames::Reserved.source_of("api").then { [_1.category, _1.source.to_sym] })
    assert_equal(%i[mailboxes rfc2142], Usernames::Reserved.source_of("ftp").then { [_1.category, _1.source.to_sym] })
    # In two files: the stricter one is its source.
    assert_equal :impersonation, Usernames::Reserved.source_of("hostmaster").category
    assert_nil Usernames::Reserved.source_of("javi")
  end

  # Every spelling of adm1n_bob2 that an entry catches, and one it never is.
  def test_the_spellings_an_impersonation_entry_catches
    spellings = %w[adm1n_bob2 adm1nbob2 adm1nbob adm n bob adminbob2 adminbob admin]

    caught = spellings.select { |entry| Usernames::Reserved.impersonation?("adm1n_bob2", Set[entry]) }

    assert_equal spellings, caught
    refute Usernames::Reserved.impersonation?("adm1n_bob2", Set["adm1n_bob", "bob2", "admi"])
  end

  # The README's recipe for the app's own official account: lift exactly
  # its name; every other spelling of it stays reserved.
  def test_the_official_account_recipe
    with_config(app_name: "YourApp", allowed: %w[yourapp], separators: %w[_ .]) do
      assert Usernames.allowed?("yourapp")
      refute Usernames.allowed?("yourapp2")
      refute Usernames.allowed?("your.app")
      refute Usernames.allowed?("your_app")
    end
  end

  def test_sets_are_compiled_once_per_rules
    rules = Usernames.configuration.rules_for

    Usernames::Reserved.verdict("javi", rules)
    sets = rules.compiled(:reserved) { flunk "compiled again" }

    assert_includes sets.impersonation, "admins"
    assert_predicate sets.exact, :frozen?
  end
end
