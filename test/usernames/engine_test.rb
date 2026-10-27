# frozen_string_literal: true

require "test_helper"
require "open3"

# What a catch-all route points at (recognize_path wants the controller to exist).
class PagesController < ActionController::Base; end

class EngineTest < UsernamesTestCase
  def engine_locales
    I18n.load_path.map(&:to_s).select { |path| path.include?("/config/locales/usernames.") }
  end

  # Its one route goes into the app's route set, not an engine of its own.
  def test_is_a_rails_engine_that_isolates_nothing_and_mounts_nothing
    assert_operator Usernames::Engine, :<, Rails::Engine
    refute_predicate Usernames::Engine, :isolated?
    assert_empty Usernames::Engine.routes.routes
  end

  def test_loads_its_locale_files
    assert_equal %w[usernames.en.yml usernames.es.yml usernames.pt.yml], engine_locales.map { |path|
      File.basename(path)
    }.sort
  end

  # So a key in the app's own config/locales always wins.
  def test_its_locale_files_load_before_the_apps
    paths = I18n.load_path.map(&:to_s)
    app_file = paths.index { |path| path.end_with?("test/fixtures/locales/app.en.yml") }

    refute_nil app_file, "the test app's locale file is loaded"
    engine_locales.each { |path| assert_operator paths.index(path), :<, app_file, path }
    assert_equal "hello", I18n.t("test_app.greeting")
  end

  def test_its_locale_files_are_loaded_once
    assert_equal engine_locales.uniq, engine_locales
  end

  def test_extends_active_record_with_has_username
    assert_kind_of Usernames::Model, ActiveRecord::Base
    assert_respond_to Member, :has_username
  end

  def test_has_username_is_on_every_model
    assert_kind_of Usernames::Model, ApplicationRecord
    assert_respond_to User, :username_available?
    assert_empty Member._usernames, "a model without has_username declares nothing"
  end

  # Routes are collected lazily and forgotten whenever they reload,
  # so a page added to config/routes.rb is reserved from the next check on.
  def test_reloading_the_routes_resets_the_reserved_routes
    Usernames::Reserved.routes
    Usernames::Reserved.instance_variable_set(:@routes, Set["stale"].freeze)

    ActiveSupport.run_load_hooks(:after_routes_loaded, Rails.application)

    refute_includes Usernames::Reserved.routes, "stale"
  end

  def test_loads_its_rake_tasks
    require "rake"
    Rake.application = Rake::Application.new
    Rails.application.load_tasks

    assert Rake::Task.task_defined?("usernames:audit")
    assert Rake::Task.task_defined?("usernames:reserved")
    # Once: Rails already loads an engine's lib/tasks, and a second load
    # would run every task twice.
    assert_equal([1, 1], %w[usernames:audit usernames:reserved].map { |task| Rake::Task[task].actions.size })
  ensure
    Rake.application = Rake::Application.new
  end

  # Active Record without Rails: `require "usernames/model"` is all it takes.
  def test_has_username_without_rails
    script = <<~RUBY
      require "bundler/setup"
      require "active_record"
      require "usernames/model"
      abort "Rails got loaded" if defined?(Rails::Engine)
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      ActiveRecord::Schema.verbose = false
      ActiveRecord::Schema.define { create_table(:people) { |t| t.string :username } }
      class Person < ActiveRecord::Base
        has_username
      end
      puts Person.create!.username_generated?
      puts Person.create(username: "admin").errors.full_messages
      puts Person.find_by_username("@" + Person.create!(username: "Javi").username).username
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)

    assert_predicate status, :success?, error
    assert_equal ["true", "Username is reserved", "javi"], output.lines(chomp: true)
  end

  def test_validates_the_configuration_after_the_app_boots
    callbacks = []
    app = Struct.new(:config).new(Struct.new(:callbacks) do
      def after_initialize(&block) = callbacks << block
    end.new(callbacks))

    initializer = Usernames::Engine.initializers.find { |each| each.name == "usernames.validate_configuration" }
    initializer.run(app)

    assert_equal 1, callbacks.size
    callbacks.first.call # a valid configuration passes

    Usernames.configuration.case = :lower
    assert_raises(Usernames::ConfigurationError) { callbacks.first.call }
  end

  def test_the_active_record_initializer_is_named
    assert(Usernames::Engine.initializers.any? { |each| each.name == "usernames.active_record" })
  end

  # A fresh process with Active Model but no Rails: no engine, the messages
  # still translate, and the extension rule falls back to its fixed list.
  def test_requires_without_rails
    script = <<~RUBY
      require "bundler/setup"
      require "usernames"
      abort "Rails got loaded" if defined?(Rails)
      abort "an engine without Rails" if defined?(Usernames::Engine)
      puts Usernames.check("_javi").message
      puts Usernames.check("javi.json", separators: %w[_ .]).reason
      puts Usernames.check("javi.csv", separators: %w[_ .]).ok?
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)

    assert_predicate status, :success?, error
    assert_equal ["can't start or end with an underscore", "username_extension", "true"], output.lines(chomp: true)
  end

  def test_the_validator_is_available_to_every_model
    assert_instance_of ActiveModel::Validations::UsernameValidator, Member.validators_on(:username).first
  end

  # --- the availability route ---------------------------------------------------------------------------

  # A route set drawn the way the app's is: the engine's append block, then `draw`.
  def drawn_routes(&block)
    routes = ActionDispatch::Routing::RouteSet.new
    initializer("usernames.routes").run(Struct.new(:routes).new(routes))
    routes.draw(&block || proc {})
    routes
  end

  def recognize(routes, path)
    routes.recognize_path(path)
  rescue ActionController::RoutingError
    nil
  end

  def initializer(name)
    Usernames::Engine.instance.initializers.find { |each| each.name == name }
  end

  def test_the_route_is_appended_after_the_apps_own
    routes = drawn_routes { get "pricing", to: "pages#pricing" }

    assert_equal(%w[/pricing(.:format) /usernames/availability], routes.routes.map { |route| route.path.spec.to_s })
    assert_equal({ controller: "usernames/availability", action: "show" }, recognize(routes, "/usernames/availability"))
    assert_nil recognize(routes, "/usernames/availability.json"), "format: false"
    assert_equal "/usernames/availability", routes.url_helpers.usernames_availability_path
  end

  def test_an_app_route_of_that_name_is_the_apps
    routes = drawn_routes { get "check", to: "names#check", as: :usernames_availability }

    assert_equal(["/check(.:format)"], routes.routes.map { |route| route.path.spec.to_s })
  end

  def test_no_path_no_route
    Usernames.configuration.availability.path = nil

    assert_empty drawn_routes.routes
    Usernames.configuration.availability.path = false

    assert_empty drawn_routes.routes
  end

  # The block reads the configuration each time the routes are drawn.
  def test_a_redraw_reads_the_path_again
    routes = drawn_routes
    Usernames.configuration.availability.path = "/handles/check"
    routes.draw { root to: "pages#home" }

    assert_equal(["/", "/handles/check"], routes.routes.map { |route| route.path.spec.to_s })
  end

  # A catch-all drawn first swallows the appended route; the routing method
  # puts it above the catch-all, and the engine then draws nothing more.
  def test_a_catch_all_needs_the_routing_method
    swallowed = drawn_routes { get "*path", to: "pages#show" }

    assert_equal "pages", recognize(swallowed, "/usernames/availability")[:controller]

    placed = drawn_routes do
      usernames_availability
      get "*path", to: "pages#show"
    end

    assert_equal "usernames/availability", recognize(placed, "/usernames/availability")[:controller]
    assert_equal 2, placed.routes.count
  end

  def test_the_routing_method_takes_a_path
    routes = drawn_routes { usernames_availability "/signup/check" }

    assert_equal "usernames/availability", recognize(routes, "/signup/check")[:controller]
    assert_equal(["/signup/check"], routes.routes.map { |route| route.path.spec.to_s })
  end

  # The endpoint's first segment is reserved like any page of the app:
  # a new prefix, after a redraw, is reserved from the next check on.
  def test_the_endpoints_first_segment_is_reserved
    assert_equal :route, Usernames.check("usernames").rule

    with_config(separators: %w[_ -]) do |config|
      config.availability.path = "/zq-check/availability"
      reload_routes

      assert_equal :route, Usernames.check("zq-check").rule
      refute_equal :route, Usernames.check("usernames").rule
    end
  ensure
    reload_routes
  end

  # As the development reloader does it: draw, then tell whoever listens.
  def reload_routes
    Rails.application.reload_routes!
    ActiveSupport.run_load_hooks(:after_routes_loaded, Rails.application)
  end

  # --- importmap and assets --------------------------------------------------------------------------

  def test_the_importmap_initializer_runs_before_importmaps_and_is_a_no_op_without_it
    pins = initializer("usernames.importmap")
    config = ActiveSupport::OrderedOptions.new

    assert_equal "importmap", pins.before
    refute defined?(::Importmap), "the test app runs without importmap-rails"
    assert_nil pins.run(Struct.new(:config).new(config))
    assert_nil config.importmap
  end

  def test_with_importmap_the_pins_and_the_sweeper_are_added
    config = ActiveSupport::OrderedOptions.new
    config.importmap = ActiveSupport::OrderedOptions.new
    config.importmap.paths = []
    config.importmap.cache_sweepers = []
    Object.const_set(:Importmap, Module.new)
    initializer("usernames.importmap").run(Struct.new(:config).new(config))

    assert_equal [Usernames::Engine.root.join("config/importmap.rb")], config.importmap.paths
    assert_equal [Usernames::Engine.root.join("app/assets/javascripts")], config.importmap.cache_sweepers
    assert_equal ['pin "usernames", to: "usernames/index.js"',
                  'pin "usernames/username-check", to: "usernames/username_check_controller.js"'],
                 File.readlines(config.importmap.paths.first, chomp: true).grep(/^pin /)
  ensure
    Object.send(:remove_const, :Importmap) if Object.const_defined?(:Importmap, false)
  end

  def test_sprockets_gets_the_path_and_both_files_to_precompile_once
    assets = ActiveSupport::OrderedOptions.new
    assets.paths = []
    assets.precompile = %w[application.js]
    2.times { Usernames::Engine.add_assets(assets) }

    assert_equal [Usernames::Engine.root.join("app/assets/javascripts").to_s], assets.paths
    assert_equal %w[application.js usernames/index.js usernames/username_check_controller.js], assets.precompile
  end

  # Propshaft has no precompile list: it serves every file on its paths.
  def test_propshaft_gets_the_path_only
    assets = ActiveSupport::OrderedOptions.new
    assets.paths = [Usernames::Engine.root.join("app/assets/javascripts")]
    Usernames::Engine.add_assets(assets)

    assert_equal 1, assets.paths.size, "already there, from the engine's own app/assets"
    assert_nil assets.precompile
  end

  def test_an_asset_pipeline_gets_the_files_through_the_initializer
    assets = ActiveSupport::OrderedOptions.new
    assets.paths = []
    assets.precompile = []
    initializer("usernames.assets").run(Struct.new(:config).new(Struct.new(:assets).new(assets)))

    assert_equal 1, assets.paths.size
    assert_equal Usernames::Engine::JAVASCRIPTS, assets.precompile
  end

  def test_no_asset_pipeline_no_assets
    runs = [Struct.new(:config).new(Struct.new(:assets).new(nil)),
            Struct.new(:config).new(Object.new)]

    runs.each { |app| assert_nil initializer("usernames.assets").run(app) }
  end

  def test_every_form_builder_has_the_helpers
    assert ActionView::Base, "the helpers arrive when Action View loads"

    assert_includes ActionView::Helpers::FormBuilder.ancestors, Usernames::FormBuilder
    assert_includes ActionDispatch::Routing::Mapper.ancestors, Usernames::Routes
  end
end
