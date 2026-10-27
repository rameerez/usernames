# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/usernames/javascript_generator"

class GeneratorJavascriptTest < Rails::Generators::TestCase
  tests Usernames::Generators::JavascriptGenerator
  destination File.expand_path("../../tmp/generator_javascript_test", __dir__)

  STIMULUS = "app/javascript/controllers/username_check_controller.js"
  SOURCE = File.expand_path("../../app/assets/javascripts/usernames/username_check_controller.js", __dir__)

  setup :prepare_destination

  def test_copies_the_gems_controller_under_a_versioned_note
    output = run_generator

    assert_file STIMULUS do |content|
      note, *rest = content.lines

      assert_equal "// Copied from the usernames gem #{Usernames::VERSION} by `rails generate usernames:javascript`. " \
                   "Run it again after upgrading the gem.\n", note
      assert_equal File.read(SOURCE), rest.join
    end
    assert_match(/stimulus:manifest:update/, output)
    assert_match(/application\.register\("username-check", UsernameCheckController\)/, output)
  end

  # Nothing but the controller: the bridge is importmap's.
  def test_copies_only_the_controller
    run_generator

    assert_equal([STIMULUS], Dir.glob("**/*", base: destination_root).select do |path|
      File.file?(File.join(destination_root, path))
    end)
  end
end
