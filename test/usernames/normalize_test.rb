# frozen_string_literal: true

require "test_helper"

class NormalizeTest < UsernamesTestCase
  # The characters that break naive normalisers: a pasted @, dotted capital I
  # (lowercases to two code points), a titlecase digraph, the Kelvin sign
  # (NFKC turns it into a Latin K), a ligature, sharp s, capital sigma and
  # dotless i.
  TRICKY = ["@", "\u{130}", "\u{1C5}", "\u{212A}", "\u{FB01}", "\u{DF}", "\u{3A3}", "\u{131}"].freeze
  WHITESPACE = [" ", "\t", "\n", "\u{A0}", "\u{3000}", "\u{2028}", "\u{85}", "\u{FEFF}", "\u{200B}", "\u{0}"].freeze
  MODES = %i[lowercase preserve].freeze

  def normalize(value, case_mode = :lowercase)
    Usernames::Normalizer.call(value, case_mode)
  end

  # ---- The documented examples ---------------------------------------------

  def test_the_readme_example
    assert_equal "javi_r", Usernames.normalize(" @Javi_R ")
    assert_equal "javi_r", Usernames.normalize("  @Javi_R ")
  end

  def test_full_width_letters_typed_on_a_cjk_keyboard_become_ascii
    assert_equal "javi", Usernames.normalize("\u{FF2A}\u{FF41}\u{FF56}\u{FF49}")
    assert_equal "Javi", Usernames.normalize("\u{FF2A}\u{FF41}\u{FF56}\u{FF49}", case: :preserve)
  end

  # Spotify 2013: the name that became somebody else's on the second pass.
  def test_superscript_letters_reach_their_final_form_in_one_pass
    bigbird = "\u{1D2E}\u{1D35}\u{1D33}\u{1D2E}\u{1D35}\u{1D3F}\u{1D30}"

    assert_equal "bigbird", Usernames.normalize(bigbird)
    assert_equal "BIGBIRD", Usernames.normalize(bigbird, case: :preserve)
    assert_equal "bigbird", Usernames.normalize(Usernames.normalize(bigbird))
  end

  def test_compatibility_characters_fold
    assert_equal "kelvin", normalize("\u{212A}elvin")
    assert_equal "fifa", normalize("\u{FB01}fa")
    assert_equal "Kelvin", normalize("\u{212A}elvin", :preserve)
  end

  def test_lowercase_mode_lowercases_and_renormalises
    assert_equal "javi", normalize("JAVI")
    assert_equal "d\u{17E}", normalize("\u{1C5}") # ǅ → dž, two code points after NFKC
    assert_equal "i\u{307}", normalize("\u{130}") # İ → i + combining dot, which the charset rule refuses
    assert_equal "stra\u{DF}e", normalize("STRA\u{DF}E")
  end

  def test_preserve_mode_keeps_the_typed_case
    assert_equal "JaVi", normalize("JaVi", :preserve)
    assert_equal "D\u{17E}", normalize("\u{1C5}", :preserve)
  end

  # ---- Trimming -------------------------------------------------------------

  def test_strips_ascii_whitespace_and_nul_at_the_edges
    assert_equal "javi", normalize("\t javi \n")
    assert_equal "javi", normalize("\u{0}javi\u{0}")
  end

  def test_unicode_spaces_at_the_edges_are_stripped_once_nfkc_makes_them_spaces
    assert_equal "javi", normalize("\u{A0}javi\u{3000}")
  end

  def test_whitespace_inside_a_name_is_kept_for_the_rules_to_refuse
    assert_equal "ja vi", normalize("ja vi")
    assert_equal "x\nadmin", normalize("x\nadmin")
  end

  # Invisible characters survive normalisation and are refused by
  # :username_characters — never stripped, because a name that silently
  # becomes another name is the bug this gem exists to prevent.
  def test_invisible_characters_are_never_stripped
    ["\u{200B}", "\u{200D}", "\u{2063}", "\u{202E}", "\u{FEFF}", "\u{2028}"].each do |invisible|
      assert_equal "ja#{invisible}vi", normalize("ja#{invisible}vi"), invisible.inspect
    end
    assert_equal "\u{2028}javi", normalize("\u{2028}javi"), "U+2028 is not ASCII whitespace, so strip keeps it"
  end

  # ---- The leading @ ----------------------------------------------------------

  def test_removes_exactly_one_pasted_at
    assert_equal "javi", normalize("@javi")
    assert_equal "javi", normalize("@Javi")
    assert_equal "Javi", normalize("@Javi", :preserve)
    assert_equal "3n", normalize("@3n")
  end

  def test_leaves_an_at_that_is_not_followed_by_a_letter_or_digit
    assert_equal "@@javi", normalize("@@javi")
    assert_equal "@_javi", normalize("@_javi")
    assert_equal "@ javi", normalize("@ javi")
    assert_equal "@", normalize("@")
    assert_equal "@", normalize(" @ ")
  end

  def test_leaves_an_at_anywhere_but_the_start
    assert_equal "javi@", normalize("javi@")
    assert_equal "ja@vi", normalize("ja@vi")
  end

  def test_the_at_is_removed_after_trimming
    assert_equal "javi", normalize("   @javi")
    assert_equal "javi", normalize("\u{3000}@JAVI")
  end

  # ---- Encodings and odd values: never raises --------------------------------

  def test_nil_and_non_strings
    assert_equal "", normalize(nil)
    assert_equal "42", normalize(42)
    assert_equal "javi", normalize(:Javi)
  end

  def test_invalid_utf8_bytes_are_dropped
    assert_equal "javi", normalize("ja\xFFvi")
    assert_equal "javi", normalize("ja\xC3vi")
  end

  def test_binary_strings_keep_only_their_ascii
    assert_equal "javi", normalize("Javi".b)
    assert_equal "jos", normalize("jos\xC3\xA9".b), "bytes of an unknown encoding are dropped, never guessed at"
  end

  def test_other_encodings_are_converted
    assert_equal "javi", normalize("Javi".encode("UTF-16LE"))
    assert_equal "jos\u{E9}", normalize("Jos\u{E9}".encode("ISO-8859-1"))
  end

  def test_invalid_utf16_does_not_raise
    broken = (+"J\x00a\x00v").force_encoding("UTF-16LE")

    assert_equal "ja", normalize(broken)
  end

  def test_a_dummy_encoding_with_no_converter_does_not_raise
    assert_equal "javi", normalize((+"Javi").force_encoding("UTF-7"))
  end

  def test_a_very_long_value_does_not_raise
    long = "a" * 54_000

    assert_equal long, normalize(long)
    assert_equal long, normalize(" #{"\u{FF41}" * 54_000} ") # full-width a, folded by NFKC
  end

  def test_returns_a_new_utf8_string_and_leaves_the_input_alone
    input = +" @Javi "
    output = normalize(input)

    assert_equal " @Javi ", input
    assert_equal Encoding::UTF_8, output.encoding
    refute_same input, output
  end

  def test_frozen_input
    assert_equal "javi", normalize(" Javi ")
  end

  # ---- Idempotence: the property that matters ---------------------------------

  def test_idempotent_over_the_big_list_of_naughty_strings
    lines = File.readlines(File.join(FIXTURES, "blns.txt"), chomp: true)

    assert_operator lines.size, :>, 700
    MODES.each do |mode|
      failures = lines.reject { |line| idempotent?(line, mode) }

      assert_empty failures, "#{mode}: not idempotent for #{failures.first(5).inspect}"
    end
  end

  def test_idempotent_over_ten_thousand_random_unicode_strings
    strings = random_strings(10_000, Random.new(20_261_027))

    MODES.each do |mode|
      failures = strings.reject { |string| idempotent?(string, mode) }

      assert_empty failures, "#{mode}: not idempotent for #{failures.first(5).map(&:dump)}"
    end
  end

  def test_idempotent_over_every_tricky_character_in_every_position
    combinations = TRICKY.product(TRICKY, ["a", "A", "_", " ", "@"]).map(&:join)

    MODES.each do |mode|
      combinations.each { |string| assert idempotent?(string, mode), "#{mode}: #{string.dump}" }
    end
  end

  # ---- Usernames.normalize / Usernames.normalizer -------------------------------

  def test_usernames_normalize_follows_the_configured_case
    with_config(case: :preserve) { assert_equal "Javi", Usernames.normalize("@Javi") }
    assert_equal "javi", Usernames.normalize("@Javi")
  end

  def test_normalizer_turns_blank_into_nil
    normalizer = Usernames.normalizer

    assert_nil normalizer.call("")
    assert_nil normalizer.call("   ")
    assert_nil normalizer.call("\u{3000}")
    assert_equal "javi", normalizer.call(" @Javi ")
  end

  # "\u{200B}" is not blank to the gem: it is a character, and the rules refuse it.
  def test_normalizer_keeps_invisible_only_values_for_the_rules_to_refuse
    assert_equal "\u{200B}", Usernames.normalizer.call("\u{200B}")
  end

  def test_normalizer_takes_per_call_options
    assert_equal "Javi", Usernames.normalizer(case: :preserve).call(" @Javi ")
  end

  def test_normalizer_reads_the_configuration_when_called
    normalizer = Usernames.normalizer

    with_config(case: :preserve) { assert_equal "Javi", normalizer.call("Javi") }
  end

  def test_normalizer_checks_its_options_when_created
    error = assert_raises(Usernames::ConfigurationError) { Usernames.normalizer(case: :upper) }

    assert_match(/case must be one of :lowercase, :preserve \(got :upper\)/, error.message)
  end

  def test_normalizer_works_with_active_record_normalizes
    model = Class.new(ApplicationRecord) do
      self.table_name = "members"
      normalizes :username, with: Usernames.normalizer
    end

    assert_equal "javi", model.new(username: " @Javi ").username
    assert_nil model.new(username: "   ").username
    assert_equal "javi", model.normalize_value_for(:username, "@JAVI")
  end

  # ---- comparison_key -------------------------------------------------------------

  def test_comparison_key
    assert_equal "javi", Usernames.comparison_key("Javi")
    assert_equal "javi", Usernames.comparison_key(" @Javi ")
    assert_equal "javi", Usernames.comparison_key("JaVi", case: :preserve)
  end

  def test_comparison_key_lowercases_ascii_only_like_postgresql_under_collate_c
    assert_equal "\u{C9}t\u{C9}", Usernames.configuration.rules_for.comparison_key("\u{C9}T\u{C9}")
  end

  def test_comparison_key_is_the_identity_on_a_lowercase_canonical_name
    rules = Usernames.configuration.rules_for

    %w[javi javi_r 3n j.d].each { |name| assert_equal name, rules.comparison_key(name) }
  end

  private

  def idempotent?(string, mode)
    once = normalize(string, mode)
    normalize(once, mode) == once
  end

  # Strings of 0–12 characters, weighted towards the characters that break
  # normalisers, with ASCII, whitespace and any Unicode scalar value mixed in.
  def random_strings(count, random)
    Array.new(count) do
      Array.new(random.rand(0..12)) { random_character(random) }.join
    end
  end

  def random_character(random)
    case random.rand(10)
    when 0..2 then TRICKY.sample(random: random)
    when 3..4 then random.rand(0x20..0x7E).chr
    when 5 then WHITESPACE.sample(random: random)
    when 6..7 then random_scalar(random, 0x80..0xFFFF)
    else random_scalar(random, 0x80..0x10FFFF)
    end
  end

  def random_scalar(random, range)
    code_point = random.rand(range)
    code_point = random.rand(range) while code_point.between?(0xD800, 0xDFFF) # surrogates are not characters
    [code_point].pack("U")
  end
end
