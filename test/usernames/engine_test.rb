# frozen_string_literal: true

require "test_helper"
require "open3"

class EngineTest < UsernamesTestCase
  def engine_locales
    I18n.load_path.map(&:to_s).select { |path| path.include?("/config/locales/usernames.") }
  end

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

  def test_has_username_is_not_available_yet
    error = assert_raises(NotImplementedError) do
      Class.new(ApplicationRecord) { has_username }
    end

    assert_match(/validates :username, username: true/, error.message)
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
end
