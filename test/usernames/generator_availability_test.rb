# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "nokogiri"
require "open3"
require "generators/usernames/availability_generator"

class GeneratorAvailabilityTest < Rails::Generators::TestCase
  tests Usernames::Generators::AvailabilityGenerator
  destination File.expand_path("../../tmp/generator_availability_test", __dir__)

  CONTROLLER = "app/controllers/usernames/availability_controller.rb"
  STIMULUS = "app/javascript/controllers/username_check_controller.js"
  PARTIAL = "app/views/usernames/_field.html.erb"
  GEM = File.expand_path("../..", __dir__)

  setup :prepare_destination
  setup do
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  def write(path, content = "")
    FileUtils.mkdir_p(File.dirname(File.join(destination_root, path)))
    File.write(File.join(destination_root, path), content)
  end

  # --- without --copy: it's built in ------------------------------------------------------------------

  def test_without_copy_it_explains_the_check_is_built_in_and_writes_nothing
    output = run_generator %w[--model=Player --column=handle]

    assert_match(/built into the usernames gem: nothing to generate/, output)
    assert_match(/f\.username_field :handle %> <%= f\.username_status :handle/, output)
    assert_match(/import "usernames"/, output)
    assert_match(/config\.availability\.targets = \{ "player" => "Player#handle" \}/, output)
    [CONTROLLER, STIMULUS, PARTIAL].each { |path| assert_no_file path }
    assert_equal "Rails.application.routes.draw do\nend\n", File.read(File.join(destination_root, "config/routes.rb"))
    refute_match(/Found files a 0\.1 install/, output)
  end

  # A 0.1 install's copies are found, and the two consistent ways out named.
  def test_files_a_0_1_install_copied_are_found
    write CONTROLLER, "class Usernames::AvailabilityController < ApplicationController; end\n"
    write STIMULUS
    write "config/routes.rb", <<~RUBY
      Rails.application.routes.draw do
        get "usernames/availability", to: "usernames/availability#show", as: :usernames_availability
      end
    RUBY
    output = run_generator

    assert_match(%r{Found files a 0\.1 install copied into this app: #{CONTROLLER}, #{STIMULUS}, config/routes\.rb}o, output)
    assert_match(/Managed \(recommended\): delete them all/, output)
    assert_match(/Customized: keep your pair, and set config\.availability\.path = nil/, output)
    assert_equal "class Usernames::AvailabilityController < ApplicationController; end\n",
                 File.read(File.join(destination_root, CONTROLLER)), "nothing is overwritten"
  end

  # --- --copy ---------------------------------------------------------------------------------------------

  def test_copy_writes_a_complete_set
    output = run_generator %w[--copy]

    assert_file CONTROLLER, /class AvailabilityController < Usernames.configuration.availability.parent_class/
    assert_file STIMULUS, /static values = \{/
    assert_file PARTIAL, /form\.username_field attribute/
    assert_file "config/routes.rb", /^  usernames_availability$/
    assert_match(/remove `import "usernames"`/, output)
    assert_match(/keep \{ "user" => "User#username" \} there/, output)
    refute_match(/Found files a 0\.1 install/, output, "its own files are not 0.1's")
  end

  # The gem's own files, word for word, under a note saying where they came from.
  def test_the_copies_are_the_gems_files
    run_generator %w[--copy]

    {
      CONTROLLER => File.join(GEM, CONTROLLER),
      STIMULUS => File.join(GEM, "app/assets/javascripts/usernames/username_check_controller.js")
    }.each do |copy, original|
      copied = File.read(File.join(destination_root, copy))

      assert_match(/Copied from the usernames gem by `rails generate usernames:availability --copy`/, copied)
      assert_equal(File.read(original).lines.reject(&:blank?),
                   copied.lines.reject { |line| line.blank? || line.include?("Copied from the usernames gem") })
    end
    assert_predicate Open3.capture2e(RbConfig.ruby, "-c", File.join(destination_root, CONTROLLER)).last, :success?
  end

  def test_re_running_copy_draws_the_route_once
    run_generator %w[--copy]
    run_generator %w[--copy --force]

    assert_equal 1, File.read(File.join(destination_root, "config/routes.rb")).scan("usernames_availability").size
  end

  # Rendered by Action View inside a real form, as the message says to.
  def test_the_partial_renders_the_helpers
    run_generator %w[--copy]
    Usernames.configuration.availability.targets = { "user" => "User#username" }
    view = ActionView::Base.with_empty_template_cache.with_view_paths([File.join(destination_root, "app/views")])
    form = ActionView::Helpers::FormBuilder.new("user", User.new, view, {})
    html = Nokogiri::HTML.fragment(view.render(partial: "usernames/field", locals: { form: form }))

    assert_equal "username-check", html.at_css("input")["data-controller"]
    assert_equal html.at_css("output")["id"], html.at_css("input")["aria-describedby"]
    assert_equal "user_username", html.at_css("label")["for"]
    assert_raises(ActionView::Template::Error, "strict locals") do
      view.render(partial: "usernames/field", locals: { form: form, unknown: true })
    end
  ensure
    Usernames.configuration = Usernames::Configuration.new
  end

  def test_the_partial_names_the_column
    run_generator %w[--copy --model=Player --column=handle]

    assert_file PARTIAL, /attribute: :handle/
  end
end
