# frozen_string_literal: true

require "test_helper"

# A store whose counter never counts (a cache whose backend is down).
class UncountingStore < ActiveSupport::Cache::MemoryStore
  def increment(*) = nil
end

# A store that raises while counting.
class FailingStore < ActiveSupport::Cache::MemoryStore
  def increment(*) = raise(IOError, "connection refused")
end

# Single-table inheritance on the personas table, and an abstract declaration.
class Character < ApplicationRecord
  self.table_name = "personas"
  has_username :handle, case: :preserve
end

class StaffCharacter < Character; end

class AbstractHandle < ApplicationRecord
  self.abstract_class = true
  has_username
end

# An app's own parent controller, with a callback of its own.
class LocalizedParent < ActionController::Base
  around_action { |_controller, action| I18n.with_locale(:es, &action) }
end

# The endpoint, through the route the engine draws in the test app.
class AvailabilityControllerTest < UsernamesTestCase
  FILE = File.expand_path("../../app/controllers/usernames/availability_controller.rb", __dir__)
  TARGETS = { "user" => "User#username", "player" => "Player#handle" }.freeze

  def setup
    super
    @logger = Rails.logger
    Rails.logger = Logger.new(IO::NULL)
    User.delete_all
    Player.delete_all
    json_renders!
  end

  def teardown
    Rails.logger = @logger
    User.delete_all
    Player.delete_all
    super
  end

  # Usernames::AvailabilityController, loaded again as the app would load
  # it under this configuration: its parent and its store are read then.
  def load_controller(store: ActiveSupport::Cache::MemoryStore.new, parent: "ActionController::Base",
                      targets: TARGETS, **settings)
    availability = Usernames.configuration.availability
    availability.parent_controller = parent
    availability.rate_limit_store = store
    availability.targets = targets
    settings.each { |name, value| availability.public_send(:"#{name}=", value) }
    Usernames.send(:remove_const, :AvailabilityController) if Usernames.const_defined?(:AvailabilityController, false)
    load FILE
    Usernames::AvailabilityController
  end

  # `raises: true` lets an exception out instead of the 500 page Rails makes of it.
  def get(username, target: "user", path: "/usernames/availability", raises: false, **query)
    query = { username: username, target: target, **query }.compact
    env = { "REMOTE_ADDR" => "1.2.3.4", "HTTP_HOST" => "localhost" }
    response = showing_exceptions(!raises) { Rack::MockRequest.new(Rails.application).get("#{path}?#{query.to_query}", env) }
    { status: response.status, cache_control: response.headers["cache-control"],
      json: (JSON.parse(response.body) if response.status == 200) }
  end

  def json(username, **) = get(username, **)[:json]

  def in_production(&)
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production"), &)
  end

  # --- answers ----------------------------------------------------------------------------------------

  def test_answers_free_invalid_and_a_uniform_taken
    load_controller
    User.create!(username: "javi", email: "j@example.com")

    assert_equal({ "state" => "free", "message" => "is available" }, json("ana"))
    assert_equal "taken", json("@Javi")["state"], "the server's normaliser first"
    taken = %w[javi admin shithead].map { |name| json(name) }

    assert_equal [{ "state" => "taken", "message" => "has already been taken" }], taken.uniq,
                 "taken, reserved and not allowed are indistinguishable"
    assert_equal({ "state" => "invalid", "message" => "can't start or end with an underscore" }, json("_javi"))
    assert_equal({ "state" => "invalid", "message" => "can't be blank" }, json("  "))
  end

  def test_another_target_has_its_own_rules
    load_controller
    Player.create!(handle: "CoolCat")

    assert_equal "taken", json("coolcat", target: "player")["state"]
    assert_equal "free", json("Cool.Cat", target: "player")["state"]
    assert_equal "invalid", json("x", target: "player")["state"], "Player's minimum is 2"
    assert_equal "invalid", json("Cool.Cat")["state"], "User has no dots"
  end

  # A host app that words its errors per model gets the same words from the
  # endpoint as from its form.
  def test_answers_in_the_models_own_words
    I18n.backend.store_translations(:en, activerecord: { errors: { models: { user: { attributes: { username: {
                                      username_edges: "starts and ends with a letter or number",
                                      taken: "belongs to someone else", blank: "is needed"
                                    } } } } } })
    load_controller
    User.create!(username: "javi", email: "j@example.com")

    assert_equal "starts and ends with a letter or number", json("_javi")["message"]
    assert_equal ["belongs to someone else"], [json("javi"), json("admin")].map { |answer| answer["message"] }.uniq
    assert_equal "is needed", json(" ")["message"]
  ensure
    I18n.backend.reload!
  end

  def test_a_free_name_is_announced_in_every_shipped_language
    load_controller
    messages = %i[en es pt].map { |locale| I18n.with_locale(locale) { json("ana")["message"] } }

    assert_equal ["is available", "está disponible", "está disponível"], messages
  end

  # Whether a name is the signed-in person's own is the browser's to say
  # (it knows the saved value): the server answers for the name alone.
  def test_ones_own_name_is_taken_to_the_server
    controller = load_controller
    me = User.create!(username: "javi", email: "j@example.com")
    controller.define_method(:current_user) { me }

    assert_equal "taken", json("javi")["state"]
  end

  def test_odd_parameters_are_invalid_not_errors
    load_controller

    assert_equal "invalid", get(nil)[:json]["state"]
    assert_equal "invalid", get(nil, "username[]" => "ana")[:json]["state"]
    assert_equal({ "state" => "invalid", "message" => "is too long (maximum is 30 characters)" }, json("a" * 100_000))
  end

  # --- targets ------------------------------------------------------------------------------------------

  def test_anything_but_a_configured_alias_is_not_found
    load_controller

    [nil, "", "User", "User#username", "member", "players", "USER", "Kernel"].each do |target|
      assert_equal 404, get("ana", target: target)[:status], target.inspect
    end
    assert_equal 404, get("ana", target: nil, "target[]" => "user")[:status]
    assert_equal 404, get("ana", target: nil, "target[user]" => "1")[:status]
  end

  def test_with_no_targets_nothing_is_published
    load_controller(targets: {})

    assert_equal 404, get("ana")[:status]
  end

  def test_not_found_is_rate_limited_and_not_cached_either
    load_controller(rate_limit: { to: 2, within: 1.minute })
    statuses = %w[x y z].map { |target| get("ana", target: target).values_at(:status, :cache_control) }

    assert_equal [[404, "no-store"], [404, "no-store"], [429, "no-store"]], statuses
  end

  # STI: a target may name a subclass, which shares the parent's names.
  def test_a_single_table_subclass_as_a_target
    load_controller(targets: { "staff" => "StaffCharacter#handle" })
    Character.delete_all
    Character.create!(handle: "Javi")

    assert_equal "taken", json("JAVI", target: "staff")["state"]
    assert_equal "free", json("Ana", target: "staff")["state"]
  ensure
    Character.delete_all
  end

  # Configured but broken is the app's mistake, said plainly — never a 404
  # that looks like an unknown alias, never an answer for a column that is gone.
  def test_a_configured_target_that_does_not_resolve_fails_closed
    { "Nobody#username" => /Nobody can't be loaded/,
      "Member#username" => /Member isn't a model that declares has_username :username/,
      "User#handle" => /User isn't a model that declares has_username :handle/,
      "AbstractHandle#username" => /AbstractHandle isn't a model/,
      "Usernames#username" => /Usernames isn't a model/ }.each do |target, why|
      load_controller(targets: { "user" => target })

      error = assert_raises(Usernames::ConfigurationError, target) { get("ana", raises: true) }

      assert_match(/\Aconfig\.availability\.targets\["user"\] is #{Regexp.escape(target.inspect)}, but /, error.message)
      assert_match why, error.message
    end
  end

  # Resolved at request time: a model reloaded in development is the new
  # class, and a declaration removed from it is noticed.
  def test_targets_are_resolved_on_every_request
    load_controller(targets: { "user" => "ReloadedUser#username" })
    Object.const_set(:ReloadedUser, Class.new(ApplicationRecord) do
      self.table_name = "users"
      has_username
    end)

    assert_equal "free", json("ana")["state"]

    Object.send(:remove_const, :ReloadedUser)
    Object.const_set(:ReloadedUser, Class.new(ApplicationRecord) { self.table_name = "users" })

    assert_raises(Usernames::ConfigurationError) { get("ana", raises: true) }
    assert_equal 500, get("ana")[:status], "fails closed through the stack too"
  ensure
    Object.send(:remove_const, :ReloadedUser) if Object.const_defined?(:ReloadedUser, false)
  end

  # --- the route --------------------------------------------------------------------------------------

  def test_the_route_takes_no_format
    load_controller

    assert_equal 200, get("ana")[:status]
    assert_equal 404, get("ana", path: "/usernames/availability.json")[:status]
    assert_equal({ controller: "usernames/availability", action: "show" },
                 Rails.application.routes.recognize_path("/usernames/availability"))
  end

  # --- the rate limit and its store ------------------------------------------------------------------

  def test_rate_limited_with_a_real_counter
    load_controller(store: ActiveSupport::Cache::MemoryStore.new)
    statuses = Array.new(31) { get("ana").values_at(:status, :cache_control) }

    assert_equal ([200] * 30) + [429], statuses.map(&:first)
    assert_equal ["no-store"], statuses.map(&:last).uniq, "the 429 is not cached either"
  end

  def test_the_store_is_the_configured_one_captured_at_load
    store = ActiveSupport::Cache::MemoryStore.new
    controller = load_controller(store: store)
    Usernames.configuration.availability.rate_limit_store = ActiveSupport::Cache::NullStore.new

    assert_same store, controller::RATE_LIMIT.store
    get("ana")

    refute_empty store.instance_variable_get(:@data), "it counted in the captured store"
  end

  def test_rails_cache_by_default
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      assert_same Rails.cache, load_controller(store: nil)::RATE_LIMIT.store
    end
  end

  def test_a_store_that_cannot_count_is_a_503_outside_development_and_test
    { ActiveSupport::Cache::NullStore.new => /NullStore, where Rails' rate_limit counts nothing/,
      UncountingStore.new => /increment returned nothing/,
      FailingStore.new => /failed to count \(IOError: connection refused\)/ }.each do |store, why|
      load_controller(store: store)
      answer = nil
      log = capture_log { in_production { answer = get("ana") } }

      assert_equal 503, answer[:status], store.class.name
      assert_equal "no-store", answer[:cache_control]
      assert_match(/availability check is off \(503\)/, log)
      assert_match why, log
    end
  end

  def test_in_development_and_test_a_store_that_cannot_count_is_unlimited_with_one_log_line
    %w[development test].each do |env|
      load_controller(store: ActiveSupport::Cache::NullStore.new)
      statuses = nil
      log = capture_log do
        Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new(env)) { statuses = Array.new(40) { get("ana")[:status] } }
      end

      assert_equal [200], statuses.uniq, env
      assert_equal 1, log.scan("isn't rate limited here").size
    end
  end

  def test_a_memory_store_warns_once
    load_controller(store: ActiveSupport::Cache::MemoryStore.new)
    log = capture_log { 3.times { get("ana") } }

    assert_equal 1, log.scan("MemoryStore").size
  end

  # --- parents ----------------------------------------------------------------------------------------

  def test_an_api_parent
    controller = load_controller(parent: "ActionController::API")
    User.create!(username: "javi", email: "j@example.com")

    assert_operator controller, :<, ActionController::API
    assert_equal({ "state" => "free", "message" => "is available" }, json("ana"))
    assert_equal "taken", json("javi")["state"]
    assert_equal 404, get("ana", target: "x")[:status]
  end

  def test_an_api_parent_is_rate_limited_and_fails_closed_too
    load_controller(parent: "ActionController::API", rate_limit: { to: 1, within: 1.minute })

    assert_equal [200, 429], Array.new(2) { get("ana")[:status] }
    load_controller(parent: "ActionController::API", store: ActiveSupport::Cache::NullStore.new)

    assert_equal(503, in_production { get("ana")[:status] })
  end

  # The parent's callbacks apply: here, its locale.
  def test_the_parents_callbacks_apply
    assert_operator load_controller(parent: "LocalizedParent"), :<, LocalizedParent
    assert_equal "está disponible", json("ana")["message"]
  end

  private

  # The app merges its own env_config over every request's env.
  def showing_exceptions(show)
    config = Rails.application.env_config
    previous = config["action_dispatch.show_exceptions"]
    config["action_dispatch.show_exceptions"] = :none unless show
    yield
  ensure
    config["action_dispatch.show_exceptions"] = previous
  end

  # Active Support 7.2's encoder passes json 3's removed `quirks_mode`, so on
  # that pairing no controller can `render json:` at all.
  def json_renders!
    ActiveSupport::JSON.encode({})
  rescue ArgumentError => e
    skip "this Active Support cannot encode JSON with this json gem (#{e.message})"
  end
end
