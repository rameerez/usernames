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

  # The generated controller for another model and column, running: its own
  # parameter, rules (dots, kept case) and table.
  def test_another_model_and_column
    controller = load_controller(ActiveSupport::Cache::MemoryStore.new, "--model=Player", "--column=handle")
    Player.create!(handle: "CoolCat")

    assert_equal "taken", get(controller, "coolcat", param: "handle")[:json]["state"]
    assert_equal "free", get(controller, "Cool.Cat", param: "handle")[:json]["state"]
    assert_equal "invalid", get(controller, "x", param: "handle")[:json]["state"], "Player's minimum is 2"
    assert_equal "invalid", get(controller, "", param: "username")[:json]["state"], "the parameter is handle"
    assert_file CONTROLLER, /activerecord\.errors\.models\.player\.attributes\.handle/
  ensure
    Player.delete_all
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
    run_generator

    _output, error, status = Open3.capture3(node, "--input-type=module", "--check",
                                            stdin_data: File.read(File.join(destination_root, STIMULUS)))

    assert_predicate status, :success?, error
  end

  # Executed, with Stimulus replaced by a bare class: what each answer leaves
  # in the status live region.
  def test_the_stimulus_controller_writes_every_answer_into_the_live_region
    run_generator
    source = File.read(File.join(destination_root, STIMULUS))
      .sub(%r{^import \{ Controller \} from "@hotwired/stimulus"$}, "class Controller {}")
      .sub("export default class extends Controller", "const UsernameCheck = class extends Controller")
    script = <<~JS
      #{source}
      const check = new UsernameCheck()
      check.hasStatusTarget = true
      check.statusTarget = { dataset: {}, textContent: "" }
      const seen = []
      for (const answer of [{ state: "free", message: "is available" }, { state: "taken", message: "has already been taken" }, null]) {
        check.render(answer)
        seen.push({ state: check.statusTarget.dataset.state, text: check.statusTarget.textContent })
      }
      console.log(JSON.stringify(seen))
    JS
    output, error, status = Open3.capture3(node, "--input-type=module", stdin_data: script)

    assert_predicate status, :success?, error
    assert_equal [{ "state" => "free", "text" => "is available" },
                  { "state" => "taken", "text" => "has already been taken" },
                  { "state" => "", "text" => "" }], JSON.parse(output)
  end

  # Rendered by Action View inside a real form, as the post-install message
  # says to: a string check cannot tell a comment that swallows ERB from one
  # that does not.
  def test_the_partial_renders_inside_a_form
    run_generator
    html = Nokogiri::HTML.fragment(render_partial(User.new(username: "javi")))
    field = html.at_css("[data-controller=username-check]")
    input = field.at_css("input[name='user[username]']")

    assert_equal "/usernames/availability", field["data-username-check-url-value"]
    assert_equal "username", field["data-username-check-param-value"]
    assert_equal "true", field["data-username-check-lowercase-value"]
    assert_equal User.username_rules_for_browser.as_json,
                 JSON.parse(field["data-username-check-rules-value"])
    assert_equal "javi", input["value"]
    assert_equal "input->username-check#check", input["data-action"]
    assert_equal "user_username_hint user_username_status", input["aria-describedby"]
    assert_nil input["pattern"], "nothing blocks submission"
    assert_equal(%w[polite polite], field.css("p[aria-live]").map { |hint| hint["aria-live"] })
  end

  def test_the_partial_of_another_model_and_column_renders
    run_generator %w[--model=Player --column=handle]
    field = Nokogiri::HTML.fragment(render_partial(Player.new, attribute: :handle))
      .at_css("[data-controller=username-check]")

    assert_equal "handle", field["data-username-check-param-value"]
    assert_equal "false", field["data-username-check-lowercase-value"], "Player keeps typed case"
    assert field.at_css("input[name='player[handle]']")
  end

  def test_the_partials_locals_are_strict
    run_generator

    assert_raises(ActionView::Template::Error) { render_partial(User.new, unknown: true) }
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

    assert_equal({ "state" => "free", "message" => "is available" }, get(controller, "ana")[:json])
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

  # A host app that words its errors per model gets the same words from the
  # endpoint as from its form.
  def test_answers_in_the_models_own_words
    I18n.backend.store_translations(:en, activerecord: { errors: { models: { user: { attributes: { username: {
                                      username_edges: "starts and ends with a letter or number",
                                      taken: "belongs to someone else", blank: "is needed"
                                    } } } } } })
    controller = load_controller(ActiveSupport::Cache::MemoryStore.new)
    User.create!(username: "javi", email: "j@example.com")

    assert_equal "starts and ends with a letter or number", get(controller, "_javi")[:json]["message"]
    assert_equal ["belongs to someone else"], [get(controller, "javi"), get(controller, "admin")].map { |answer|
      answer[:json]["message"]
    }.uniq
    assert_equal "is needed", get(controller, " ")[:json]["message"]
  ensure
    I18n.backend.reload!
  end

  def test_a_free_name_is_announced_in_every_shipped_language
    controller = load_controller(ActiveSupport::Cache::MemoryStore.new)
    messages = %i[en es pt].map { |locale| I18n.with_locale(locale) { get(controller, "ana")[:json]["message"] } }

    assert_equal ["is available", "está disponible", "está disponível"], messages
  end

  def test_the_signed_in_persons_own_name_is_free
    controller = load_controller(ActiveSupport::Cache::MemoryStore.new)
    me = User.create!(username: "javi", email: "j@example.com")
    controller.define_method(:current_user) { me }

    assert_equal({ "state" => "free", "message" => "is available" }, get(controller, "Javi")[:json])
    assert_equal "taken", get(controller, "admin")[:json]["state"]
  end

  def test_rate_limited
    controller = load_controller(ActiveSupport::Cache::MemoryStore.new)
    statuses = Array.new(31) { get(controller, "ana").values_at(:status, :cache_control) }

    assert_equal ([200] * 30) + [429], statuses.map(&:first)
    assert_equal ["no-store"], statuses.map(&:last).uniq, "the 429 is not cached either"
  end

  def test_a_null_store_in_production_is_a_503_with_a_log_line
    controller = load_controller(ActiveSupport::Cache::NullStore.new)
    answer = nil
    log = capture_log { Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) { answer = get(controller, "ana") } }

    assert_equal 503, answer[:status]
    assert_equal "no-store", answer[:cache_control]
    assert_match(/availability check is off \(503\).*NullStore/, log)
    assert_equal 200, get(controller, "ana")[:status], "outside production the NullStore only means no limit"
  end

  def test_a_memory_store_warns_once
    controller = load_controller(ActiveSupport::Cache::MemoryStore.new)
    log = capture_log { 3.times { get(controller, "ana") } }

    assert_equal 1, log.scan("MemoryStore").size
  end

  private

  # The generated partial, rendered by Action View with a form builder for
  # `record`, the way `render "usernames/field", form: form` renders it.
  def render_partial(record, **locals)
    view = ActionView::Base.with_empty_template_cache
      .with_view_paths([File.join(destination_root, "app/views")])
    view.define_singleton_method(:usernames_availability_path) { "/usernames/availability" }
    form = ActionView::Helpers::FormBuilder.new(record.model_name.param_key, record, view, {})
    view.render(partial: "usernames/field", locals: { form: form, **locals })
  end

  # The generated file, loaded into the test app with `store` as its cache.
  def load_controller(store, *arguments)
    json_renders!
    run_generator arguments
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

  def get(controller, value, param: "username")
    env = Rack::MockRequest.env_for("/usernames/availability?#{param}=#{CGI.escape(value)}", "REMOTE_ADDR" => "1.2.3.4")
    status, headers, body = controller.action(:show).call(env)
    text = +""
    body.each { |part| text << part }
    { status: status, headers: headers, cache_control: headers["cache-control"],
      json: (JSON.parse(text) if status == 200) }
  end

  def node
    found = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "node") }.find do |path|
      File.executable?(path)
    end
    found || skip("node is not installed")
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
