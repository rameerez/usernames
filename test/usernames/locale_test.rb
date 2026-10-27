# frozen_string_literal: true

require "test_helper"

# The availability check's own messages: the current locale, else English as
# I18n has it, else the gem's English straight from its YAML file.
class LocaleTest < UsernamesTestCase
  def teardown
    I18n.backend.reload!
    super
  end

  def test_the_current_locale_wins
    assert_equal "no se pudo comprobar ahora", I18n.with_locale(:es) { Usernames::Locale.t(:usernames, :availability, :error) }
    assert_equal "is available", Usernames::Locale.t(:usernames, :available)
  end

  def test_the_apps_own_wording_wins
    I18n.backend.eager_load!
    I18n.backend.store_translations(:es, usernames: { availability: { error: "ahora no" } })

    assert_equal "ahora no", I18n.with_locale(:es) { Usernames::Locale.t(:usernames, :availability, :error) }
  end

  # A language without the key: English as I18n has it, the app's included.
  def test_a_language_without_the_key_reads_english
    I18n.available_locales += [:fr]
    I18n.backend.eager_load! # the files first, so they don't load over the app's wording
    I18n.backend.store_translations(:en, usernames: { availability: { error: "try again later" } })

    assert_equal "try again later", I18n.with_locale(:fr) { Usernames::Locale.t(:usernames, :availability, :error) }
  ensure
    I18n.available_locales -= [:fr]
  end

  def test_the_gems_english_comes_from_its_yaml_file
    english = YAML.load_file(Usernames::Locale::ENGLISH)["en"]

    assert_equal english.dig("usernames", "availability", "error"),
                 Usernames::Locale.english(:usernames, :availability, :error)
    assert_equal "is available", Usernames::Locale.english(:usernames, :available)
  end

  # English never loaded (a French-only app): the gem's English still.
  def test_a_backend_without_english
    available = I18n.available_locales
    I18n.available_locales = %i[fr]
    I18n.locale = :fr
    I18n.backend.reload!

    assert_equal "couldn't be checked just now", Usernames::Locale.t(:usernames, :availability, :error)
    assert_equal "is available", Usernames::Locale.t(:usernames, :available)
  ensure
    I18n.available_locales = available
    I18n.locale = :en
  end
end
