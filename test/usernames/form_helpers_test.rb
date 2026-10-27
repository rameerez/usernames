# frozen_string_literal: true

require "test_helper"
require "nokogiri"

# A controller of the app, whose views have its routes and `main_app`.
class FormsController < ActionController::Base; end

# Single-table inheritance on the personas table.
class Avatar < ApplicationRecord
  self.table_name = "personas"
  has_username :handle, case: :preserve
end

class StaffAvatar < Avatar; end

# A model with has_username that no target names.
class UnlistedUser < ApplicationRecord
  self.table_name = "users"
  has_username
end

class FormHelpersTest < UsernamesTestCase
  def setup
    super
    Usernames.configuration.availability.targets = { "user" => "User#username", "player" => "Player#handle" }
    User.delete_all
  end

  def teardown
    User.delete_all
    super
  end

  def view(script_name: "")
    controller = FormsController.new
    # As the router hands it over: mounted at SCRIPT_NAME, routed by the app.
    controller.request = ActionDispatch::TestRequest.create("SCRIPT_NAME" => script_name,
                                                            "action_dispatch.routes" => Rails.application.routes)
    controller.view_context
  end

  def builder(record, view: self.view, **options)
    ActionView::Helpers::FormBuilder.new(record.model_name.param_key, record, view, options)
  end

  def field(record, column = :username, view: self.view, form: {}, **html)
    Nokogiri::HTML.fragment(builder(record, view: view, **form).username_field(column, **html)).at_css("input")
  end

  def status(record, column = :username, form: {}, **html)
    Nokogiri::HTML.fragment(builder(record, **form).username_status(column, **html)).at_css("output")
  end

  def data(input)
    input.attributes.select { |name, _| name.start_with?("data-") }.transform_values(&:value)
  end

  # --- the field ------------------------------------------------------------------------------------

  def test_every_attribute_of_a_checked_field
    input = field(User.new)

    assert_equal "user_username", input["id"]
    assert_equal "user[username]", input["name"]
    assert_equal({ "data-controller" => "username-check", "data-action" => "input->username-check#check",
                   "data-username-check-rules-value" => JSON.generate(User.username_rules_for_browser),
                   "data-username-check-lowercase-value" => "true",
                   "data-username-check-status-id-value" => "user_username_status",
                   "data-username-check-url-value" => "/usernames/availability",
                   "data-username-check-target-value" => "user",
                   "data-username-check-error-message-value" => "couldn't be checked just now" }, data(input))
    assert_equal "user_username_status", input["aria-describedby"]
    assert_equal %w[username none off false],
                 attributes(input, "autocomplete", "autocapitalize", "autocorrect", "spellcheck")
    assert_nil input["maxlength"], "the rules carry the length; maxlength would cut a pasted @name"
    assert_nil input["pattern"], "nothing blocks submission"
  end

  def test_the_rules_and_messages_are_the_models
    I18n.backend.store_translations(:en, activerecord: { errors: { models: { user: { attributes: { username: {
                                      username_edges: "starts and ends with a letter or number"
                                    } } } } } })
    rules = JSON.parse(field(User.new)["data-username-check-rules-value"])

    assert_includes rules.map { |rule| rule["message"] }, "starts and ends with a letter or number"
  ensure
    I18n.backend.reload!
  end

  # A language the app translates the gem into but that lacks this newer
  # key: the English text, never "Translation missing".
  def test_the_error_message_falls_back_to_english
    I18n.available_locales += [:fr]
    I18n.backend.store_translations(:fr, usernames: { available: "est disponible" })
    message = I18n.with_locale(:fr) { field(User.new)["data-username-check-error-message-value"] }

    assert_equal "couldn't be checked just now", message
    assert_equal "no se pudo comprobar ahora",
                 I18n.with_locale(:es) { field(User.new)["data-username-check-error-message-value"] }
  ensure
    I18n.available_locales -= [:fr]
    I18n.backend.reload!
  end

  # Where English isn't an available locale, the gem's English still is the fallback.
  def test_the_english_fallback_needs_no_english_locale
    available = I18n.available_locales
    I18n.available_locales = %i[es fr]
    I18n.locale = :fr
    message = field(User.new)["data-username-check-error-message-value"]

    assert_equal "couldn't be checked just now", message
  ensure
    I18n.available_locales = available
    I18n.locale = :en
  end

  def test_a_preserve_mode_column
    input = field(Player.new, :handle)

    assert_equal "false", input["data-username-check-lowercase-value"]
    assert_equal "player", input["data-username-check-target-value"]
    assert_equal "player_handle_status", input["aria-describedby"]
  end

  def test_the_persisted_value_is_the_saved_one
    assert_nil field(User.new(username: "typed"))["data-username-check-persisted-value"], "a new record has none"

    user = User.create!(username: "javi", email: "j@example.com")
    user.username = "attempted"

    assert_equal "javi", field(user)["data-username-check-persisted-value"], "never an unsaved attempt"
    assert_equal "attempted", field(user)["value"]
  end

  def test_the_persisted_value_is_escaped
    user = User.create!(email: "j@example.com")
    user.update_column(:username, %(a"><script>))

    assert_equal %(a"><script>), field(user)["data-username-check-persisted-value"]
    refute_includes builder(user).username_field(:username), "<script>"
  end

  # Through the app's route helper, so a sub-URI deployment's prefix is in it.
  def test_the_url_comes_from_the_apps_route
    assert_equal "/sub/usernames/availability",
                 field(User.new, view: view(script_name: "/sub"))["data-username-check-url-value"]
  end

  # A view without the app's routes (or an app that drew none): format hints only.
  def test_without_a_route_the_field_only_hints
    Usernames.configuration.availability.targets = {}
    input = field(User.new, view: ActionView::Base.empty)

    assert_equal "username-check", input["data-controller"]
    assert_nil input["data-username-check-url-value"]
    assert_nil input["data-username-check-target-value"]
  end

  # A single-table subclass's form uses the target that names its parent.
  def test_a_subclass_form_finds_its_parents_target
    with_targets("avatar" => "Avatar#handle") do
      assert_equal "avatar", field(StaffAvatar.new, :handle)["data-username-check-target-value"]
    end
    with_targets("avatar" => "Avatar#handle", "staff" => "StaffAvatar#handle") do
      assert_equal "staff", field(StaffAvatar.new, :handle)["data-username-check-target-value"], "its own first"
    end
  end

  # --- the switches -----------------------------------------------------------------------------------

  def test_availability_false_keeps_the_format_hints
    input = field(User.new, availability: false)

    assert_equal "username-check", input["data-controller"]
    assert input["data-username-check-rules-value"]
    assert_equal "user_username_status", input["aria-describedby"]
    %w[url target error-message].each { |value| assert_nil input["data-username-check-#{value}-value"], value }
  end

  def test_availability_false_needs_no_target
    Usernames.configuration.availability.targets = {}

    assert field(UnlistedUser.new, availability: false)
  end

  def test_static_is_a_plain_field
    input = field(User.new, static: true, class: "input")

    assert_empty data(input)
    assert_nil input["aria-describedby"]
    assert_equal %w[username input], attributes(input, "autocomplete", "class")
    assert field(Member.new, static: true), "any model at all"
  end

  # --- a column no target names -------------------------------------------------------------------------

  def test_a_column_no_target_names_is_a_configuration_error_in_development_and_test
    error = assert_raises(Usernames::ConfigurationError) { field(UnlistedUser.new) }

    assert_match(/no entry in config\.availability\.targets names UnlistedUser#username: add \{ "unlisted_user" => "UnlistedUser#username" \}/,
                 error.message)
  end

  def test_in_production_a_column_no_target_names_renders_a_plain_field_and_logs_once
    Usernames::Field::MISSING_TARGET_LOGGED.make_false
    inputs = []
    log = capture_log do
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
        inputs = Array.new(2) { field(UnlistedUser.new) }
      end
    end

    inputs.each { |input| assert_empty data(input) }
    assert_equal 1, log.scan("renders without its check").size
  end

  def test_a_form_for_a_model_without_has_username
    error = assert_raises(ArgumentError) { field(Member.new) }

    assert_match(/username_field :username needs a form for a model with has_username :username/, error.message)
  end

  # --- merging --------------------------------------------------------------------------------------------

  def test_token_lists_join_the_callers
    input = field(User.new, class: "input wide", data: { controller: "autosize", action: "blur->form#save" },
                            aria: { describedby: "handle_help" })

    assert_equal "input wide", input["class"]
    assert_equal "autosize username-check", input["data-controller"]
    assert_equal "blur->form#save input->username-check#check", input["data-action"]
    assert_equal "handle_help user_username_status", input["aria-describedby"]
  end

  # Token values the way Rails takes them: Arrays, and Hashes whose truthy
  # keys count.
  def test_array_and_conditional_hash_token_values
    input = field(User.new, class: ["input", { wide: true, narrow: false }],
                            data: { controller: ["autosize", { tooltip: true, hidden: nil }] },
                            aria: { describedby: ["help", { rules: true, legacy: false }] })

    assert_equal "input wide", input["class"]
    assert_equal "autosize tooltip username-check", input["data-controller"]
    assert_equal "help rules user_username_status", input["aria-describedby"]
  end

  def test_token_values_are_deduplicated_and_split
    input = field(User.new, aria: { describedby: [" help  rules ", "user_username_status", nil] })

    assert_equal "help rules user_username_status", input["aria-describedby"]
  end

  def test_attributes_given_as_plain_keys_are_merged_the_same_way
    input = field(User.new, "data-controller" => "autosize", "aria-describedby" => "handle_help", "data-x" => "1")

    assert_equal "autosize username-check", input["data-controller"]
    assert_equal "handle_help user_username_status", input["aria-describedby"]
    assert_equal "1", input["data-x"]
  end

  def test_the_callers_other_data_and_aria_are_kept_and_the_fields_own_values_win
    skip_unless_json_encodes # Rails encodes a non-String data value as JSON
    input = field(User.new, data: { username_check_delay_value: 500, username_check_url_value: "/elsewhere",
                                    turbo_permanent: true },
                            aria: { label: "Handle" })

    assert_equal "500", input["data-username-check-delay-value"]
    assert_equal "/usernames/availability", input["data-username-check-url-value"]
    assert_equal "true", input["data-turbo-permanent"]
    assert_equal "Handle", input["aria-label"]
  end

  def test_scalar_options_are_the_callers
    input = field(User.new, autocomplete: "nickname", maxlength: 30, placeholder: "javi", required: true)

    assert_equal %w[nickname 30 javi required],
                 attributes(input, "autocomplete", "maxlength", "placeholder", "required")
  end

  # --- ids, and two forms for one record -------------------------------------------------------------------

  def test_the_status_is_an_output_for_the_input
    output = status(User.new)

    assert_equal "user_username_status", output["id"]
    assert_equal "user_username", output["for"]
    assert_equal "polite", output["aria-live"]
    assert_nil output["name"], "never submitted"
    assert_empty output.text
  end

  def test_the_status_merges_the_callers_attributes
    output = status(User.new, class: "hint", aria: { atomic: true, live: "assertive" }, data: { testid: "s" },
                              for: "elsewhere")

    assert_equal %w[hint polite true s], attributes(output, "class", "aria-live", "aria-atomic", "data-testid")
    assert_equal "user_username", output["for"], "the status is for its field"
  end

  def test_two_forms_for_the_same_record_with_namespaces
    user = User.new
    first, second = %w[signup sidebar].map { |namespace| field(user, form: { namespace: namespace }) }
    statuses = %w[signup sidebar].map { |namespace| status(user, form: { namespace: namespace }) }

    assert_equal %w[signup_user_username sidebar_user_username], [first["id"], second["id"]]
    assert_equal([first["id"], second["id"]], statuses.map { |output| output["for"] })
    assert_equal(statuses.map { |output| output["id"] }, [first, second].map { |input| input["aria-describedby"] })
    assert_equal(statuses.map { |output| output["id"] },
                 [first, second].map { |input| input["data-username-check-status-id-value"] })
  end

  def test_an_id_given_to_both_helpers
    input = field(User.new, id: "handle")
    output = status(User.new, id: "handle")

    assert_equal "handle", input["id"]
    assert_equal "handle_status", input["aria-describedby"]
    assert_equal %w[handle_status handle], attributes(output, "id", "for")
  end

  # Rails prefixes a form's namespace to an id it is given, too.
  def test_an_id_given_to_both_helpers_in_a_namespaced_form
    input = field(User.new, id: "handle", form: { namespace: "signup" })
    output = status(User.new, id: "handle", form: { namespace: "signup" })

    assert_equal "signup_handle", input["id"]
    assert_equal "signup_handle_status", input["aria-describedby"]
    assert_equal %w[signup_handle_status signup_handle], attributes(output, "id", "for")
  end

  # A field's own `namespace:` is the one Rails prefixes, over the form's:
  # the status follows it, given to both helpers.
  def test_a_per_field_namespace
    {
      [{ namespace: "3" }, {}] => "3_user_username",
      [{ namespace: "3", id: "handle" }, {}] => "3_handle",
      [{}, { namespace: "signup" }] => "signup_user_username",
      [{ namespace: "3" }, { namespace: "signup" }] => "3_user_username",
      [{ namespace: "3", id: "handle" }, { namespace: "signup" }] => "3_handle"
    }.each do |(options, form), id|
      input = field(User.new, form: form, **options)
      output = status(User.new, form: form, **options)

      assert_equal id, input["id"], options.inspect
      assert_equal "#{id}_status", input["aria-describedby"]
      assert_equal "#{id}_status", input["data-username-check-status-id-value"]
      assert_equal ["#{id}_status", id], attributes(output, "id", "for")
      assert_nil output["namespace"], "consumed, not rendered"
    end
  end

  # So is a field's own `index:`: in its id as Rails puts it in its name.
  def test_a_per_field_index
    input = field(User.new, index: 3)
    output = status(User.new, index: 3)

    assert_equal "user[3][username]", input["name"]
    assert_equal "user_3_username", input["id"]
    assert_equal "user_3_username_status", input["aria-describedby"]
    assert_equal %w[user_3_username_status user_3_username], attributes(output, "id", "for")
    assert_equal "user_3_username_status", field(User.new, index: 3, form: { index: 9 })["aria-describedby"]
  end

  def test_an_indexed_form
    input = field(User.new, form: { index: 3 })

    assert_equal "user_3_username", input["id"]
    assert_equal "user_3_username_status", input["aria-describedby"]
  end

  # Rendered by form_with in a real template, as an app writes it.
  def test_inside_form_with
    html = view.render(inline: <<~ERB, locals: { user: User.new })
      <%= form_with model: user, url: "/signup" do |f| %>
        <%= f.label :username %> <%= f.username_field :username %> <%= f.username_status :username %>
      <% end %>
    ERB
    page = Nokogiri::HTML.fragment(html)

    assert_equal page.at_css("label")["for"], page.at_css("input[data-controller]")["id"]
    assert_equal page.at_css("output")["id"], page.at_css("input[data-controller]")["aria-describedby"]
  end

  private

  def attributes(element, *names)
    names.map { |name| element[name] }
  end

  def with_targets(targets)
    previous = Usernames.configuration.availability.targets
    Usernames.configuration.availability.targets = targets
    yield
  ensure
    Usernames.configuration.availability.targets = previous
  end
end
