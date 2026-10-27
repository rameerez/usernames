# frozen_string_literal: true

require "test_helper"
require "open3"

# A fresh Rails app, booted in its own process the way an app boots — with
# and without Propshaft and importmap-rails, with eager loading on and off —
# then asked for the availability route, an answer, its importmap and its
# compiled assets. The main test app can't show this: it boots once, with
# neither.
class BootTest < UsernamesTestCase
  ROOT = File.expand_path("../..", __dir__)

  APP = <<~RUBY
    require "bundler/setup"
    require "json"
    require "logger"
    require "rails"
    require "active_record/railtie"
    require "action_controller/railtie"
    if ENV["WITH_ASSETS"] == "1"
      require "propshaft"
      require "importmap-rails"
    end
    require "usernames"

    class BootApp < Rails::Application
      config.root = ENV.fetch("APP_ROOT")
      config.eager_load = ENV["EAGER_LOAD"] == "1"
      config.secret_key_base = "a" * 64
      config.logger = Logger.new(nil)
      config.hosts.clear
      config.active_support.deprecation = :silence
    end
    Usernames.configure { |config| config.availability.targets = { "user" => "User#username" } }
    Rails.application.initialize!

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define { create_table(:users) { |t| t.string :username } }
    class User < ActiveRecord::Base
      has_username
    end

    # Read first: recognising the route loads the controller.
    result = { "controller_loaded_at_boot" => Usernames.autoload?(:AvailabilityController).nil? }
    result.merge!(
      "route" => Rails.application.routes.recognize_path("/usernames/availability"),
      "reserved" => Usernames.check("usernames").rule,
      "importmap" => defined?(Importmap) ? true : false
    )
    # Active Support 7.2's encoder passes json 3's removed `quirks_mode`: on
    # that pairing nothing in Rails can encode JSON, the importmap included.
    result["json"] = begin
      ActiveSupport::JSON.encode({})
      true
    rescue ArgumentError
      false
    end
    if result["json"]
      response = Rack::MockRequest.new(Rails.application)
        .get("/usernames/availability?username=ana&target=user", "HTTP_HOST" => "localhost")
      result["answer"] = [response.status, JSON.parse(response.body)]
    end
    if defined?(Importmap)
      result["pins"] = Rails.application.importmap.packages.keys
      if result["json"]
        result["map"] = JSON.parse(Rails.application.importmap.to_json(resolver: ActionController::Base.helpers))["imports"]
      end
      result["compiled"] =
        if result["json"] # compiled for real; the manifest is JSON too
          Rails.application.assets.processor.process
          Dir.glob("usernames/*.js", base: Rails.root.join("public/assets").to_s).sort
        else
          %w[usernames/index.js usernames/username_check_controller.js].map do |path|
            Rails.application.assets.load_path.find(path).digested_path.to_s
          end
        end
    end
    puts JSON.generate(result)
  RUBY

  def boot(assets:, eager_load:)
    root = File.join(ROOT, "tmp", "boot", "#{assets ? 'assets' : 'plain'}-#{eager_load ? 'eager' : 'lazy'}")
    FileUtils.rm_rf(root)
    FileUtils.mkdir_p(File.join(root, "config"))
    File.write(File.join(root, "config", "importmap.rb"), "")
    File.write(File.join(root, "config", "database.yml"),
               "development:\n  adapter: sqlite3\n  database: \":memory:\"\n")
    env = { "APP_ROOT" => root, "WITH_ASSETS" => assets ? "1" : "0", "EAGER_LOAD" => eager_load ? "1" : "0",
            "RAILS_ENV" => "development" }
    output, error, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-e", APP, chdir: ROOT)

    assert_predicate status, :success?, error
    JSON.parse(output.lines.last)
  end

  def assert_the_check_works(result)
    assert_equal({ "controller" => "usernames/availability", "action" => "show" }, result["route"])
    assert_equal "route", result["reserved"], "the endpoint's own first segment is reserved"
    return unless result["json"]

    assert_equal [200, { "state" => "free", "message" => "is available" }], result["answer"]
  end

  def test_without_importmap_or_propshaft
    [false, true].each do |eager_load|
      result = boot(assets: false, eager_load: eager_load)

      assert_the_check_works(result)
      refute result["importmap"]
      assert_equal eager_load, result["controller_loaded_at_boot"], "eager loading loads the endpoint at boot"
    end
  end

  def test_with_importmap_and_propshaft
    result = boot(assets: true, eager_load: true)

    assert_the_check_works(result)
    assert_includes result["pins"], "usernames"
    assert_includes result["pins"], "usernames/username-check"
    assert_match %r{\Ausernames/index-\h+\.js usernames/username_check_controller-\h+\.js\z},
                 result["compiled"].join(" ")
    skip "this Active Support cannot encode JSON with this json gem" unless result["json"]

    assert_match %r{\A/assets/usernames/index-\h+\.js\z}, result["map"]["usernames"]
    assert_match %r{\A/assets/usernames/username_check_controller-\h+\.js\z}, result["map"]["usernames/username-check"]
    assert_equal result["map"].values_at("usernames", "usernames/username-check").map { |path|
      path.delete_prefix("/assets/")
    },
                 result["compiled"], "both files compile, under the digests the importmap names"
  end

  def test_with_importmap_and_lazy_loading
    result = boot(assets: true, eager_load: false)

    assert_the_check_works(result)
    refute result["controller_loaded_at_boot"]
  end
end
