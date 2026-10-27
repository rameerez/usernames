# frozen_string_literal: true

require "test_helper"

# The format rules, in order, first failure wins.
class FormatRulesTest < UsernamesTestCase
  # Every code point of Unicode's White_Space property — what \p{Space} matches.
  WHITE_SPACE = [*0x09..0x0D, 0x20, 0x85, 0xA0, 0x1680, *0x2000..0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
    .map { |code_point| [code_point].pack("U") }.freeze

  # Look like spaces, are not White_Space: refused as characters instead.
  NOT_WHITE_SPACE = ["\u{200B}", "\u{FEFF}", "\u{180E}", "\u{2060}", "\u{0}"].freeze

  # The reason a name gets from the full pipeline (normalise, then rules).
  def reason(value, **)
    Usernames.check(value, **).reason
  end

  # The reason a value gets AS SUPPLIED — what the validator sees.
  def supplied(value, **)
    Usernames.configuration.rules_for(**).failure_for(value)&.reason
  end

  # ---- The shared table ---------------------------------------------------------

  def test_every_row_of_the_shared_table
    username_table.each do |input, expected, options|
      result = Usernames.check(input, **options)

      if expected == :ok
        assert_predicate result, :ok?, "#{input.dump} #{options} should be allowed, got #{result.reason.inspect}"
      else
        assert_equal expected, result.reason, "#{input.dump} #{options}"
      end
    end
  end

  # ---- Rule 1: no whitespace ----------------------------------------------------

  def test_every_white_space_code_point_inside_a_name_is_a_space
    WHITE_SPACE.each do |space|
      assert_equal :username_spaces, supplied("ja#{space}vi"), "U+#{space.ord.to_s(16).upcase}"
      assert_equal :username_spaces, reason("ja#{space}vi"), "U+#{space.ord.to_s(16).upcase} after normalising"
    end
  end

  def test_whitespace_at_the_edges_fails_as_supplied_but_is_trimmed_by_check
    assert_equal :username_spaces, supplied(" javi")
    assert_equal :username_spaces, supplied("javi\n")
    assert_nil reason(" javi\n")
  end

  def test_space_lookalikes_are_characters_not_spaces
    NOT_WHITE_SPACE.each do |character|
      assert_equal :username_characters, supplied("ja#{character}vi"), character.dump
    end
  end

  # The regex everyone copies anchors with ^ and $, which are line anchors in Ruby.
  def test_a_newline_never_smuggles_a_second_name_in
    assert_equal :username_spaces, reason("x\nadmin")
    assert_equal :username_spaces, supplied("x\nadmin")
    assert_equal :username_spaces, supplied("javi\n_")
    assert_equal :username_spaces, supplied("validuser\n"), "a trailing newline is not trimmed from a value as supplied"
  end

  # ---- Rule 2: allowed characters only --------------------------------------------

  def test_every_printable_ascii_character_outside_the_set_is_refused
    allowed = [*"a".."z", *"0".."9", "_"]

    (0x20..0x7E).map(&:chr).each do |character|
      next if character == " "

      if allowed.include?(character)
        assert_nil supplied("ja#{character}vi"), character.inspect
      else
        assert_equal :username_characters, supplied("ja#{character}vi"), character.inspect
      end
    end
  end

  def test_uppercase_fails_as_supplied_in_lowercase_mode
    assert_equal :username_characters, supplied("Javi")
    assert_nil reason("Javi"), "check normalises Javi to javi first"
  end

  def test_uppercase_is_allowed_in_preserve_mode
    assert_nil supplied("JaVi", case: :preserve)
  end

  def test_separators_are_allowed_only_when_configured
    assert_equal :username_characters, supplied("ja.vi")
    assert_equal :username_characters, supplied("ja-vi")
    assert_nil supplied("ja.vi", separators: %w[.])
    assert_nil supplied("ja-vi", separators: %w[-])
    assert_equal :username_characters, supplied("ja_vi", separators: %w[-])
  end

  def test_no_separators_at_all
    assert_nil supplied("javi", separators: [])
    assert_equal :username_characters, supplied("ja_vi", separators: [])
  end

  def test_non_ascii_letters_get_the_unicode_message
    %w[josé иван jаvi straße 张伟].each do |name|
      assert_equal :username_unicode, supplied(name), name
    end
  end

  def test_combining_marks_count_as_letters_for_the_message
    assert_equal :username_unicode, supplied("jose\u{301}")
    assert_equal :username_unicode, reason("\u{130}smail"), "İ lowercases to i + U+0307"
  end

  def test_any_non_letter_offender_makes_it_a_characters_error
    assert_equal :username_characters, supplied("jos\u{E9}!")
    assert_equal :username_characters, supplied("Jos\u{E9}"), "uppercase ASCII is an offender in lowercase mode"
    assert_equal :username_characters, supplied("javi\u{1F600}")
    assert_equal :username_characters, supplied("ja\u{202E}vi")
  end

  def test_value_with_broken_bytes_as_supplied_is_a_characters_error
    assert_equal :username_characters, supplied("ja\xFFvi")
    assert_equal :username_characters, supplied("jos\xC3\xA9".b)
    assert_equal :username_characters, supplied((+"j\x00a").force_encoding("UTF-16LE"))
  end

  def test_value_in_another_valid_encoding_is_judged_by_its_characters
    assert_nil supplied("javi".encode("UTF-16LE"))
    assert_nil supplied("javi".b)
  end

  def test_non_string_values_are_judged_as_their_string
    assert_equal :username_digits_only, supplied(12_345)
    assert_nil supplied(:javi)
  end

  # ---- Rule 3: length --------------------------------------------------------------

  def test_default_length_boundaries
    assert_equal :too_short, supplied("")
    assert_equal :too_short, supplied("ab")
    assert_nil supplied("abc")
    assert_nil supplied("a" * 30)
    assert_equal :too_long, supplied("a" * 31)
  end

  def test_custom_length_boundaries
    assert_equal :too_short, supplied("a", length: 2..15)
    assert_nil supplied("ab", length: 2..15)
    assert_nil supplied("a" * 15, length: 2..15)
    assert_equal :too_long, supplied("a" * 16, length: 2..15)
    assert_nil supplied("a", length: 1..1)
    assert_equal :too_long, supplied("ab", length: 1..1)
  end

  def test_an_exclusive_range_means_what_it_says
    assert_nil supplied("a" * 29, length: 3...30)
    assert_equal :too_long, supplied("a" * 30, length: 3...30)
  end

  def test_length_failures_carry_the_limit
    rules = Usernames.configuration.rules_for(length: 2..15)

    assert_equal({ count: 2 }, rules.failure_for("a").details)
    assert_equal({ count: 15 }, rules.failure_for("a" * 16).details)
  end

  def test_a_very_long_value_is_refused_quickly
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_equal :too_long, reason("a" * 54_000)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1
  end

  # ---- Rule 4: no separator at an edge ------------------------------------------------

  def test_separators_at_either_edge
    every = %w[_ . -]

    every.each do |separator|
      assert_equal :username_edges, supplied("#{separator}javi", separators: every), separator
      assert_equal :username_edges, supplied("javi#{separator}", separators: every), separator
    end
  end

  def test_edge_separators_allows_underscores_and_dashes_but_never_a_dot
    every = %w[_ . -]

    assert_nil supplied("_javi_", separators: every, edge_separators: true)
    assert_nil supplied("-javi-", separators: every, edge_separators: true)
    assert_equal :username_edges, supplied(".javi", separators: every, edge_separators: true)
    assert_equal :username_edges, supplied("javi.", separators: every, edge_separators: true)
  end

  def test_edge_failures_name_the_separators_that_may_not_be_at_an_edge
    every = %w[_ . -]

    phrase = Usernames.configuration.rules_for(separators: every).failure_for("_ab").details[:edge_separators_phrase]

    assert_equal "an underscore, a period or a dash", phrase.to_s
    assert_equal "a period",
                 Usernames.configuration.rules_for(separators: every, edge_separators: true)
                   .failure_for(".ab").details[:edge_separators_phrase].to_s
  end

  # ---- Rule 5: no two separators in a row ----------------------------------------------

  def test_every_pair_of_separators_in_a_row
    every = %w[_ . -]

    every.product(every).each do |first, second|
      assert_equal :username_consecutive, supplied("ja#{first}#{second}vi", separators: every), first + second
    end
    assert_nil supplied("a_b.c-d", separators: every)
  end

  # A real production handle that must be refused.
  def test_oliver
    assert_equal :username_consecutive, reason("oliver.__-hjj", separators: %w[_ . -])
    assert_equal :username_consecutive, reason("oliver.__-hjj", separators: %w[_ . -], edge_separators: true)
    assert_equal :username_characters, reason("oliver.__-hjj")
  end

  def test_doubled_separators_are_refused_even_where_edges_are_allowed
    assert_equal :username_consecutive, supplied("__javi", edge_separators: true)
  end

  # ---- Rule 6: first character ----------------------------------------------------------

  def test_a_leading_digit_is_allowed_by_default
    assert_nil supplied("3nn")
    assert_nil supplied("1abc")
  end

  def test_first_character_letter
    assert_equal :username_first_character, supplied("3nn", first_character: :letter)
    assert_nil supplied("nn3", first_character: :letter)
    assert_nil supplied("Nn3", first_character: :letter, case: :preserve)
    assert_equal :username_first_character, supplied("_nn", first_character: :letter, edge_separators: true)
  end

  # ---- Rule 7: not all digits --------------------------------------------------------------

  def test_all_digits
    assert_equal :username_digits_only, supplied("123")
    assert_equal :username_digits_only, supplied("000")
    assert_equal :username_digits_only, supplied("231640921")
    assert_nil supplied("0a0")
    # No letter anywhere reads as a number, whatever sits between the digits.
    assert_equal :username_digits_only, supplied("123_456")
  end

  # ---- Rule 8: no file-extension ending (only with dots) ------------------------------------

  def test_every_fixed_extension_is_refused_when_dots_are_on
    Usernames::Rules::FILE_EXTENSIONS.each do |extension|
      assert_equal :username_extension, supplied("john.#{extension}", separators: %w[_ .]), extension
    end
  end

  def test_every_extension_rails_knows_is_refused
    Mime::EXTENSION_LOOKUP.each_key do |extension|
      assert_equal :username_extension, supplied("john.#{extension}", separators: %w[_ .]), extension
    end
  end

  def test_extensions_are_matched_case_insensitively
    assert_equal :username_extension, supplied("john.JSON", separators: %w[_ .], case: :preserve)
    assert_equal :username_extension, supplied("John.Git", separators: %w[_ .], case: :preserve)
  end

  def test_an_extension_the_app_registers_is_refused_by_rules_built_afterwards
    Mime::Type.register "application/x-usernames-test", :usernamestest

    assert_equal :username_extension, supplied("john.usernamestest", separators: %w[_ .])
  ensure
    Mime::Type.unregister(:usernamestest)
  end

  def test_names_with_dots_that_do_not_end_like_a_file
    assert_nil supplied("john.doe", separators: %w[_ .])
    assert_nil supplied("json.john", separators: %w[_ .])
    assert_nil supplied("john.jsonx", separators: %w[_ .])
  end

  def test_the_extension_rule_is_off_without_dots
    assert_nil supplied("john_json")
    assert_nil supplied("john-json", separators: %w[-])
    refute(Usernames.configuration.rules_for.format_checks.any? { |reason, *| reason == :username_extension })
  end

  def test_the_extension_rule_works_without_action_dispatch
    Usernames::Rules.stub(:rails_extensions, []) do
      assert_equal :username_extension, supplied("john.json", separators: %w[_ .])
      assert_nil supplied("john.csv", separators: %w[_ .]), "csv is a Rails Mime type, not one of the fixed list"
    end
  end

  # ---- Order: the first failing rule wins ------------------------------------------------------

  def test_order
    assert_equal :username_spaces, supplied("_A b")         # 1 before 2
    assert_equal :username_characters, supplied("_A")       # 2 before 3
    assert_equal :too_short, supplied("_a")                 # 3 before 4
    assert_equal :too_short, supplied("__")
    assert_equal :username_edges, supplied("__a")           # 4 before 5
    assert_equal :username_edges, supplied("_1_")           # 4 before 7
    assert_equal :username_consecutive, supplied("1__1")    # 5 before 7
    assert_equal :username_first_character, supplied("1234", first_character: :letter) # 6 before 7
    assert_equal :username_edges, supplied(".json", separators: %w[_ .])               # 4 before 8
    assert_equal :username_consecutive, supplied("a..json", separators: %w[_ .])       # 5 before 8
  end

  def test_the_rules_are_listed_in_the_documented_order
    reasons = Usernames.configuration.rules_for(separators: %w[_ .],
                                                first_character: :letter).format_checks.map(&:first)

    assert_equal %i[username_spaces username_unicode username_characters too_short too_long username_edges
                    username_consecutive username_first_character username_digits_only username_extension], reasons
  end

  # ---- Server regexes anchor with \A and \z ---------------------------------------------------------

  def test_server_regexes_do_not_use_line_anchors
    rules = Usernames.configuration.rules_for(separators: %w[_ . -], first_character: :letter)
    regexes = rules.format_checks.map { |check| check[1] }.grep(Regexp)

    regexes.each do |regex|
      refute_match(/(?<!\\)[$]|(?<![\[\\])\^/, regex.source, "#{regex.inspect} uses ^ or $")
    end
  end

  def test_edge_and_digit_rules_ignore_line_boundaries
    checks = Usernames.configuration.rules_for.format_checks.to_h { |reason, test, _source| [reason, test] }

    refute_match checks.fetch(:username_edges), "a\n_b"
    refute_match checks.fetch(:username_digits_only), "12\nab"
  end

  # ---- Messages ----------------------------------------------------------------------------------------

  def test_messages_for_the_default_rules
    assert_equal "can't contain spaces", Usernames.check("ja vi").message
    assert_equal "can only contain lowercase letters, numbers and underscores", Usernames.check("ja.vi").message
    assert_equal "can only use the letters a–z (no accents or other alphabets)", Usernames.check("jos\u{E9}").message
    assert_equal "is too short (minimum is 3 characters)", Usernames.check("ab").message
    assert_equal "is too long (maximum is 30 characters)", Usernames.check("a" * 31).message
    assert_equal "can't start or end with an underscore", Usernames.check("_javi").message
    assert_equal "can't have two symbols in a row", Usernames.check("ja__vi").message
    assert_equal "can't be only numbers", Usernames.check("12345").message
  end

  def test_messages_that_depend_on_the_options
    assert_equal "can only contain letters, numbers and underscores", Usernames.check("ja.vi", case: :preserve).message
    assert_equal "can only contain lowercase letters, numbers, underscores and periods",
                 Usernames.check("ja-vi", separators: %w[_ .]).message
    assert_equal "can only contain lowercase letters and numbers", Usernames.check("ja_vi", separators: []).message
    assert_equal "can't start or end with a dash", Usernames.check("-javi", separators: %w[-]).message
    assert_equal "must start with a letter", Usernames.check("3nn", first_character: :letter).message
    assert_equal "can't end like a file name (.json, .png…)", Usernames.check("john.json", separators: %w[_ .]).message
    assert_equal "is too short (minimum is 1 character)", Usernames.check("", length: 1..5).message
  end

  # The format reasons, derived from the rules themselves: every reason a
  # format check can give under any options, in the order they are checked,
  # and nothing else.
  def test_format_reasons_are_what_the_format_rules_give
    produced = [{}, { separators: %w[_ . -], first_character: :letter }, { separators: [] }, { case: :preserve },
                { separators: %w[.], edge_separators: true }].flat_map do |options|
      Usernames.configuration.rules_for(**options).format_checks.map(&:first)
    end

    assert_equal produced.uniq.sort, Usernames::Rules.format_reasons.sort
    assert_equal Usernames.configuration.rules_for.format_checks.map(&:first),
                 Usernames::Rules.format_reasons & Usernames.configuration.rules_for.format_checks.map(&:first),
                 "in the order the rules check"
    assert_predicate Usernames::Rules.format_reasons, :frozen?
  end

  # Every format failure the fixture table expects is one; no content one is.
  def test_the_table_agrees_with_the_format_reasons
    reasons = username_table.map { |_input, expected, _options| expected } - [:ok]
    content = %i[username_reserved username_not_allowed]

    assert_empty reasons - content - Usernames::Rules.format_reasons
    assert_empty content & Usernames::Rules.format_reasons
  end
end
