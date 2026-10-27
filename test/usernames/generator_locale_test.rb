# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/usernames/locale_generator"

class GeneratorLocaleTest < Rails::Generators::TestCase
  tests Usernames::Generators::LocaleGenerator
  destination File.expand_path("../../tmp/generator_locale_test", __dir__)

  setup :prepare_destination

  ENGLISH = File.expand_path("../../config/locales/usernames.en.yml", __dir__)

  def test_copies_the_english_file_under_the_new_key
    output = run_generator %w[--locale=fr]

    assert_file "config/locales/usernames.fr.yml" do |content|
      assert_match(/^fr:$/, content)
      refute_match(/^en:$/, content)
      assert_includes content, %(username_reserved: "is reserved")
      assert_includes content, "rails generate usernames:locale --locale=fr"
      assert_equal File.read(ENGLISH).sub(/^en:$/, "fr:"), content.lines.drop(1).join
    end
    assert_match(/ready to translate/, output)
  end

  def test_the_copy_is_valid_yaml_with_every_key
    run_generator %w[--locale=pt-BR]

    copy = YAML.safe_load_file(File.join(destination_root, "config/locales/usernames.pt-BR.yml"))
    english = YAML.safe_load_file(ENGLISH)

    assert_equal english["en"], copy["pt-BR"]
  end

  def test_a_shipped_locale_is_mentioned
    assert_match(/already ships es/, run_generator(%w[--locale=es]))
  end

  def test_a_bad_locale_is_refused
    error = capture(:stderr) { run_generator %w[--locale=../../etc] }

    assert_match(/--locale must be a locale like fr/, error)
    assert_no_file "config/locales/usernames.../../etc.yml"
  end

  def test_re_running_is_idempotent
    run_generator %w[--locale=fr]

    assert_match(%r{identical\s+config/locales/usernames.fr.yml}, run_generator(%w[--locale=fr]))
  end
end
