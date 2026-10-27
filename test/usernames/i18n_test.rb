# frozen_string_literal: true

require "test_helper"

class I18nTest < UsernamesTestCase
  LOCALES = %i[en es pt].freeze

  # Every error type a username can get.
  TYPES = %i[
    too_short too_long blank taken
    username_spaces username_characters username_characters_without_separators username_unicode
    username_edges username_consecutive username_first_character username_digits_only
    username_extension username_reserved username_not_allowed
  ].freeze

  INTERPOLATIONS = { count: 3, letters: "LETTERS", separators_phrase: "SEPARATORS",
                     edge_separators_phrase: "EDGE" }.freeze

  LOCALE_FILES = Dir[File.expand_path("../../config/locales/usernames.*.yml", __dir__)].freeze

  COUNTS = [1, 3].freeze
  MESSAGE_SCOPE = %i[errors messages].freeze

  SEPARATORS = %w[_ . -].freeze
  SUBSETS = (1..3).flat_map { |size| SEPARATORS.permutation(size).to_a }.freeze

  # ---- Every type, every locale ------------------------------------------------

  def test_every_type_is_translated_in_every_locale
    LOCALES.each do |locale|
      TYPES.each do |type|
        COUNTS.each do |count|
          message = I18n.t(type, scope: MESSAGE_SCOPE, locale: locale, raise: true, **INTERPOLATIONS, count: count)

          assert_kind_of String, message, "#{locale}.#{type}"
          refute_includes message, "%{", "#{locale}.#{type} left an interpolation behind"
          refute_empty message.strip
        end
      end
    end
  end

  def test_the_shipped_locales_are_exactly_en_es_pt
    assert_equal %w[en es pt], LOCALE_FILES.map { |path| File.basename(path)[/usernames\.(\w+)\.yml/, 1] }.sort
  end

  def test_every_locale_file_has_the_same_keys
    keys = LOCALE_FILES.to_h do |path|
      tree = YAML.load_file(path)
      [File.basename(path), flatten(tree.values.first)]
    end

    assert_equal 1, keys.values.uniq.size, keys.transform_values(&:size).inspect
  end

  def test_each_file_holds_only_its_own_locale
    LOCALE_FILES.each do |path|
      locale = File.basename(path)[/usernames\.(\w+)\.yml/, 1]

      assert_equal [locale], YAML.load_file(path).keys
    end
  end

  # A message never repeats what was typed.
  def test_no_message_interpolates_the_value
    LOCALE_FILES.each do |path|
      refute_match(/%\{value\}/, File.read(path).lines.grep_v(/\A\s*#/).join, File.basename(path))
    end
  end

  def test_only_the_documented_interpolations_are_used
    used = LOCALE_FILES.flat_map { |path| File.read(path).lines.grep_v(/\A\s*#/).join.scan(/%\{(\w+)\}/).flatten }.uniq

    assert_empty used - %w[count letters separators_phrase edge_separators_phrase]
  end

  def test_the_engine_files_are_loaded
    LOCALE_FILES.each { |path| assert_includes I18n.load_path.map(&:to_s), path }
  end

  # ---- English, exactly as the README words it --------------------------------------

  def test_the_english_messages
    expected = {
      username_spaces: "can't contain spaces",
      username_digits_only: "can't be only numbers",
      username_consecutive: "can't have two symbols in a row",
      username_reserved: "is reserved",
      username_not_allowed: "isn't allowed",
      taken: "has already been taken",
      blank: "can't be blank"
    }

    expected.each { |type, text| assert_equal text, I18n.t(type, scope: %i[errors messages]) }
    assert_equal "is too short (minimum is 3 characters)", I18n.t(:too_short, scope: %i[errors messages], count: 3)
    assert_equal "is too long (maximum is 1 character)", I18n.t(:too_long, scope: %i[errors messages], count: 1)
  end

  # ---- The separators phrase, for every separator subset -----------------------------

  def test_separators_phrase_in_english
    {
      %w[_] => "underscores", %w[.] => "periods", %w[-] => "dashes",
      %w[_ .] => "underscores and periods", %w[. _] => "periods and underscores",
      %w[_ -] => "underscores and dashes", %w[. -] => "periods and dashes",
      %w[_ . -] => "underscores, periods and dashes", %w[- . _] => "dashes, periods and underscores"
    }.each do |separators, phrase|
      assert_equal phrase, Usernames::Phrase.separators(separators).to_s, separators.inspect
    end
  end

  def test_separators_phrase_in_spanish_and_portuguese
    I18n.with_locale(:es) do
      assert_equal "guiones bajos", Usernames::Phrase.separators(%w[_]).to_s
      assert_equal "guiones bajos y puntos", Usernames::Phrase.separators(%w[_ .]).to_s
      assert_equal "guiones bajos, puntos y guiones", Usernames::Phrase.separators(%w[_ . -]).to_s
    end
    I18n.with_locale(:pt) do
      assert_equal "sublinhados", Usernames::Phrase.separators(%w[_]).to_s
      assert_equal "sublinhados e pontos", Usernames::Phrase.separators(%w[_ .]).to_s
      assert_equal "sublinhados, pontos e hífens", Usernames::Phrase.separators(%w[_ . -]).to_s
    end
  end

  def test_every_subset_in_every_locale_names_each_separator_once
    LOCALES.each do |locale|
      I18n.with_locale(locale) do
        SUBSETS.each do |separators|
          phrase = Usernames::Phrase.separators(separators).to_s
          words = separators.map { |separator| I18n.t(:plural, scope: [:usernames, :separators, Usernames::Phrase::SEPARATOR_NAMES[separator]]) }

          # Each word in turn, in the configured order ("guiones" is inside
          # "guiones bajos", so the phrase is consumed rather than searched).
          rest = phrase
          words.each do |word|
            index = rest.index(word)

            refute_nil index, "#{locale} #{separators.inspect}: #{word.inspect} missing or out of order in #{phrase.inspect}"
            rest = rest[(index + word.size)..]
          end

          refute_match(/translation missing/i, phrase)
        end
      end
    end
  end

  def test_any_separator_phrase
    assert_equal "an underscore", Usernames::Phrase.any_separator(%w[_]).to_s
    assert_equal "an underscore or a period", Usernames::Phrase.any_separator(%w[_ .]).to_s
    assert_equal "an underscore, a period or a dash", Usernames::Phrase.any_separator(%w[_ . -]).to_s
    I18n.with_locale(:es) { assert_equal "un guion bajo o un punto", Usernames::Phrase.any_separator(%w[_ .]).to_s }
    I18n.with_locale(:pt) { assert_equal "um sublinhado ou um hífen", Usernames::Phrase.any_separator(%w[_ -]).to_s }
  end

  def test_no_separators_is_an_empty_phrase
    assert_equal "", Usernames::Phrase.separators([]).to_s
  end

  def test_letters_phrase
    assert_equal "lowercase letters", Usernames::Phrase.letters(:lowercase).to_s
    assert_equal "letters", Usernames::Phrase.letters(:preserve).to_s
    I18n.with_locale(:es) { assert_equal "letras minúsculas", Usernames::Phrase.letters(:lowercase).to_s }
  end

  # ---- The characters message, for every separator subset ------------------------------

  def test_characters_message_reads_as_one_sentence_for_every_subset
    {
      %w[_] => "can only contain lowercase letters, numbers and underscores",
      %w[-] => "can only contain lowercase letters, numbers and dashes",
      %w[_ .] => "can only contain lowercase letters, numbers, underscores and periods",
      %w[_ . -] => "can only contain lowercase letters, numbers, underscores, periods and dashes",
      [] => "can only contain lowercase letters and numbers"
    }.each do |separators, message|
      assert_equal message, Usernames.check("ja@vi", separators: separators).message, separators.inspect
    end
  end

  def test_characters_message_in_every_locale_and_case
    I18n.with_locale(:es) do
      assert_equal "solo puede contener letras minúsculas, números, guiones bajos y puntos",
                   Usernames.check("ja@vi", separators: %w[_ .]).message
      assert_equal "solo puede contener letras y números",
                   Usernames.check("ja@vi", separators: [], case: :preserve).message
    end
    I18n.with_locale(:pt) do
      assert_equal "só pode conter letras minúsculas, números e sublinhados", Usernames.check("ja@vi").message
    end
  end

  def test_edges_message_in_every_locale
    assert_equal "can't start or end with an underscore or a dash",
                 Usernames.check("_javi", separators: %w[_ -]).message
    I18n.with_locale(:es) do
      assert_equal "no puede empezar ni terminar con un guion bajo", Usernames.check("_javi").message
    end
    I18n.with_locale(:pt) do
      assert_equal "não pode começar nem terminar com um ponto",
                   Usernames.check(".javi", separators: %w[_ .], edge_separators: true).message
    end
  end

  def test_every_format_failure_has_a_message_in_every_locale
    inputs = {
      "ja vi" => {}, "ja@vi" => {}, "ja@vi " => { separators: [] }, "jos\u{E9}" => {}, "ab" => {}, "a" * 31 => {},
      "_ab" => {}, "a__b" => {}, "1ab" => { first_character: :letter }, "123" => {},
      "a.json" => { separators: %w[_ .] }
    }

    LOCALES.each do |locale|
      I18n.with_locale(locale) do
        inputs.each do |input, options|
          message = Usernames.check(input, **options).message

          refute_match(/translation missing|%\{/i, message, "#{locale} #{input.inspect}")
        end
      end
    end
  end

  # ---- The phrase is translated when the message is read ----------------------------------

  def test_a_phrase_is_translated_when_read
    phrase = Usernames::Phrase.separators(%w[_ .])

    assert_equal "underscores and periods", phrase.to_s
    I18n.with_locale(:es) { assert_equal "guiones bajos y puntos", phrase.to_s }
  end

  def test_a_phrase_reads_as_text_everywhere
    phrase = Usernames::Phrase.separators(%w[_])

    assert_equal "underscores", phrase.call({})
    assert_equal "underscores", phrase.as_json
    assert_equal '"underscores"', phrase.inspect
    assert_equal "a underscores b", I18n.interpolate("a %{x} b", x: phrase)
  end

  def test_result_messages_are_in_the_current_locale
    I18n.with_locale(:es) { assert_equal "es demasiado corto (3 caracteres mínimo)", Usernames.check("ab").message }
    I18n.with_locale(:pt) { assert_equal "é muito curto (mínimo: 3 caracteres)", Usernames.check("ab").message }
  end

  private

  def flatten(tree, prefix = nil)
    tree.flat_map do |key, value|
      path = [prefix, key].compact.join(".")
      value.is_a?(Hash) ? flatten(value, path) : [path]
    end.sort
  end
end
