# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/usernames/availability_generator"

class GeneratorAvailabilityTest < Rails::Generators::TestCase
  tests Usernames::Generators::AvailabilityGenerator
  destination File.expand_path("../../tmp/generator_availability_test", __dir__)

  CONTROLLER = "app/controllers/usernames/availability_controller.rb"
  STIMULUS = "app/javascript/controllers/username_check_controller.js"
  PARTIAL = "app/views/usernames/_field.html.erb"

  setup :prepare_destination
  setup do
    @logger = Rails.logger
    Rails.logger = Logger.new(IO::NULL)
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
    User.delete_all
  end
  teardown do
    Rails.logger = @logger
    User.delete_all
    Usernames.send(:remove_const, :AvailabilityController) if Usernames.const_defined?(:AvailabilityController, false)
  end

  # --- the files ------------------------------------------------------------------------------------

  def test_writes_the_four_pieces
    output = run_generator

    assert_file CONTROLLER, /class AvailabilityController < ApplicationController/
    assert_file "config/routes.rb",
                %r{get "usernames/availability", to: "usernames/availability#show", as: :usernames_availability}
    assert_file STIMULUS
    assert_file PARTIAL
    assert_match(%r{render "usernames/field", form: form}, output)
    assert_match(/shared cache store/, output)
  end

  def test_the_controller_follows_the_prd
    run_generator

    assert_file CONTROLLER do |content|
      assert_includes content, "RATE_LIMIT_STORE = cache_store"
      assert_includes content, "rate_limit to: 30, within: 1.minute, store: RATE_LIMIT_STORE, " \
                               "with: -> { head :too_many_requests }"
      assert_includes content, "when ActiveSupport::Cache::NullStore"
      assert_includes content, "head :service_unavailable"
      assert_includes content, %(response.headers["Cache-Control"] = "no-store")
      assert_includes content, "User.username_available?(result.canonical)"
      assert_includes content, "params[:username]"
    end
  end

  def test_another_model_and_column
    run_generator %w[--model=Player --column=handle]

    assert_file CONTROLLER, /Player\.handle_available\?/, /params\[:handle\]/, /Player\.handle_options/
    assert_file PARTIAL, /data-username-check-param-value="handle"/, /attribute: :handle/
  end

  def test_the_stimulus_controller_only_hints
    run_generator

    assert_file STIMULUS do |content|
      refute_match(%r{^[^/]*setCustomValidity}, content, "nothing blocks submission")
      refute_match(%r{^[^/]*\.pattern\s*=}, content)
      assert_includes content, %(normalize("NFKC"))
      assert_includes content, "delay: { type: Number, default: 300 }"
      assert_includes content, "new AbortController()"
      assert_includes content, "if (name === this.current) this.render(answer)"
    end
  end

  def test_the_stimulus_controller_is_valid_javascript
    node = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "node") }.find do |path|
      File.executable?(path)
    end
    skip "node is not installed" unless node
    run_generator

    _output, error, status = Open3.capture3(node, "--input-type=module", "--check",
                                            stdin_data: File.read(File.join(destination_root, STIMULUS)))

    assert_predicate status, :success?, error
  end

  def test_the_partial_wires_the_controller
    run_generator

    assert_file PARTIAL do |content|
      assert_includes content, %(data-controller="username-check")
      assert_includes content, "Usernames.rules_for_browser(**User.username_options).to_json"
      assert_includes content, "usernames_availability_path"
      assert_includes content, %(input->username-check#check)
      assert_includes content, "<%# locals: (form:, attribute: :username, label: nil) -%>"
      refute_includes content, "pattern:"
    end
  end

  def test_re_running_adds_the_route_once
    run_generator
    run_generator

    routes = File.read(File.join(destination_root, "config/routes.rb"))

    assert_equal 1, routes.scan("usernames/availability#show").size
  end

  # --- the generated controller, running ------------------------------------------------------------

  def test_answers_free_invalid_and_a_uniform_taken
    controller = load_controller(ActiveSupport::Cache::MemoryStore.new)
    User.create!(username: "javi", email: "j@example.com")

    assert_equal({ "state" => "free", "message" => nil }, get(controller, "ana")[:json])
    assert_equal "taken", get(controller, "@Javi")[:json]["state"]
    taken = [get(controller, "javi"), get(controller, "admin"), get(controller, "shithead")].map do |answer|
      answer[:json]
    end

    assert_equal [{ "state" => "taken", "message" => "has already been taken" }], taken.uniq,
                 "taken, reserved and not allowed are indistinguishable"
    assert_equal({ "state" => "invalid", "message" => "can't start or end with an underscore" },
                 get(controller, "_javi")[:json])
    assert_equal({ "state" => "invalid", "message" => "can't be blank" }, get(controller, "  ")[:json])
    assert_equal "no-store", get(controller, "ana")[:headers]["cache-control"]
  end

  def test_the_signed_in_persons_own_name_is_free
    controller = load_controller(ActiveSupport::Cache::MemoryStore.new)
    me = User.create!(username: "javi", email: "j@example.com")
    controller.define_method(:current_user) { me }

    assert_equal "free", get(controller, "Javi")[:json]["state"]
    assert_equal "taken", get(controller, "admin")[:json]["state"]
  end

  def test_rate_limited
    controller = load_controller(ActiveSupport::Cache::MemoryStore.new)
    statuses = Array.new(31) { get(controller, "ana")[:status] }

    assert_equal ([200] * 30) + [429], statuses
  end

  def test_a_null_store_in_production_is_a_503_with_a_log_line
    controller = load_controller(ActiveSupport::Cache::NullStore.new)
    answer = nil
    log = capture_log { Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) { answer = get(controller, "ana") } }

    assert_equal 503, answer[:status]
    assert_match(/availability check is off \(503\).*NullStore/, log)
    assert_equal 200, get(controller, "ana")[:status], "outside production the NullStore only means no limit"
  end

  def test_a_memory_store_warns_once
    controller = load_controller(ActiveSupport::Cache::MemoryStore.new)
    log = capture_log { 3.times { get(controller, "ana") } }

    assert_equal 1, log.scan("MemoryStore").size
  end

  private

  # The generated file, loaded into the test app with `store` as its cache.
  def load_controller(store)
    json_renders!
    run_generator
    Object.const_set(:ApplicationController, Class.new(ActionController::Base)) unless defined?(::ApplicationController)
    ::ApplicationController.cache_store = store
    load File.join(destination_root, CONTROLLER)
    Usernames::AvailabilityController
  end

  # Active Support 7.2's encoder passes json 3's removed `quirks_mode`, so on
  # that pairing no controller can `render json:` at all.
  def json_renders!
    ActiveSupport::JSON.encode({})
  rescue ArgumentError => e
    skip "this Active Support cannot encode JSON with this json gem (#{e.message})"
  end

  def get(controller, username)
    env = Rack::MockRequest.env_for("/usernames/availability?username=#{CGI.escape(username)}", "REMOTE_ADDR" => "1.2.3.4")
    status, headers, body = controller.action(:show).call(env)
    text = +""
    body.each { |part| text << part }
    { status: status, headers: headers, json: (JSON.parse(text) if status == 200) }
  end

  def capture_log
    output = StringIO.new
    previous = Rails.logger
    Rails.logger = Logger.new(output)
    yield
    output.string
  ensure
    Rails.logger = previous
  end
end
