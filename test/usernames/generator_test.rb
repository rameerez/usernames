# frozen_string_literal: true

require "test_helper"

# Default and seeded names (PRD §12).
class GeneratorTest < UsernamesTestCase
  ADJECTIVE = Usernames::Words::ADJECTIVES.first
  ANIMAL = Usernames::Words::ANIMALS.first

  # SecureRandom pinned: every word pick is the first of its list and every
  # number the lowest of its range, so a batch is fully predictable.
  def predictably(hex: "2b9f6d", &)
    lowest = ->(arg) { arg.is_a?(Range) ? arg.min : 0 }
    SecureRandom.stub(:random_number, lowest) { SecureRandom.stub(:hex, hex, &) }
  end

  def candidates(from: nil, **)
    Usernames::Generator.candidates(from: from, rules: Usernames.configuration.rules_for(**))
  end

  def assert_all_allowed(names, **)
    refute_empty names
    names.each { |name| assert_predicate Usernames.check(name, **), :ok?, name }
    assert_equal names.uniq, names
  end

  def test_the_default_shape
    names = candidates

    assert_operator names.size, :>, 15
    assert_operator names.size, :<=, Usernames::Generator::DRAWS
    names.each { |name| assert_match(/\A[a-z]+_[a-z]+_[0-9a-f]{2,6}\z/, name) }
    assert_all_allowed names
    assert_match(/\A[a-z]+_[a-z]+_\d{2}\z/, Usernames.generate)
  end

  def test_digits_grow_through_the_batch
    names = predictably { candidates }

    assert_equal %W[#{ADJECTIVE}_#{ANIMAL}_10 #{ADJECTIVE}_#{ANIMAL}_100 #{ADJECTIVE}_#{ANIMAL}_1000
                    #{ADJECTIVE}_#{ANIMAL}_2b9f6d], names
  end

  def test_the_draw_schedule
    drawn = []
    record = lambda do |arg|
      drawn << arg if arg.is_a?(Range)
      arg.is_a?(Range) ? arg.min : 0
    end
    SecureRandom.stub(:random_number, record) { SecureRandom.stub(:hex, "2b9f6d") { candidates } }

    assert_equal ([10..99] * 3) + ([100..999] * 2) + ([1000..9999] * 3), drawn
  end

  def test_the_first_separator_joins
    predictably do
      assert_equal "#{ADJECTIVE}.#{ANIMAL}.10", candidates(separators: %w[.]).first
      assert_equal "#{ADJECTIVE}-#{ANIMAL}-10", candidates(separators: %w[- _]).first
    end
  end

  def test_the_adjective_goes_when_the_pair_does_not_fit
    predictably do
      long = "#{ADJECTIVE}_#{ANIMAL}_10".length
      names = candidates(length: 3..(long - 1))

      assert_equal "#{ANIMAL}_10", names.first
    end
  end

  def test_short_lengths
    { 2..2 => /\A[a-z]{2}\z/, 2..15 => /\A[a-z0-9_]{2,15}\z/, 3..8 => /\A[a-z0-9]{3,8}\z/ }.each do |length, shape|
      names = candidates(length: length)

      names.each { |name| assert_match shape, name, length.inspect }
      assert_all_allowed names, length: length
    end
  end

  def test_compact_shapes_for_a_short_maximum
    predictably do
      assert_equal "#{ANIMAL[0, 6]}10", candidates(length: 3..8).first
      assert_equal("#{ANIMAL[0, 1]}1000", candidates(length: 3..5).find { |name| name.end_with?("1000") })
    end
  end

  def test_random_letters_when_no_letter_fits_beside_the_digits
    predictably do
      assert_equal %w[aa], candidates(length: 2..2)
      assert_equal %w[aaaaaaaa], candidates(length: 8..9, generator: { nouns: %w[ox] }).grep(/\A[a-z]+\z/)
    end
  end

  def test_no_separators
    names = candidates(separators: [])

    names.each { |name| assert_match(/\A[a-z]+[0-9a-f]+\z/, name) }
    assert_all_allowed names, separators: []
  end

  def test_every_candidate_passes_the_full_check_under_its_rules
    [{}, { length: 3..12 }, { separators: %w[-] }, { case: :preserve }, { first_character: :letter }].each do |options|
      assert_all_allowed candidates(**options), **options
    end
  end

  # --- from: ---------------------------------------------------------------------------------------

  def test_from_a_name
    assert_equal "jose_garcia", Usernames.generate(from: "Jos\u{E9} Garc\u{ED}a")
    assert_equal "Jose_Garcia", Usernames.generate(from: "Jos\u{E9} Garc\u{ED}a", case: :preserve)
    assert_equal "jose.garcia", Usernames.generate(from: "  jos\u{E9}.garc\u{ED}a ", separators: %w[. _])
    assert_equal "josegarcia", Usernames.generate(from: "Jos\u{E9} Garc\u{ED}a", separators: [])
  end

  def test_from_seeds_the_batch_then_fills_it
    names = predictably { candidates(from: "Pedro") }

    assert_equal %W[pedro pedro_10 pedro_100 #{ADJECTIVE}_#{ANIMAL}_10], names.first(4)
    assert_all_allowed names
  end

  def test_from_cleaning
    {
      "  @Javi!! R " => "javi_r",
      "O'Brien--Smith" => "o_brien_smith",
      "Mar\u{ED}a  de la O" => "maria_de_la_o",
      "Stra\u{DF}e" => "strasse",
      "info@acme.com" => "acme",
      "Javi+news@example.com" => "javi",
      "Hello@Festival-Planner.io" => "festival_planner",
      "maria.lopez@example.com" => "maria_lopez"
    }.each do |seed, expected|
      assert_equal expected, Usernames::Generator.clean(seed, Usernames.configuration.rules_for), seed
    end
  end

  def test_from_cyrillic_without_any_ascii_falls_back_to_default_shapes
    refute defined?(::AnyAscii)
    names = candidates(from: "\u{418}\u{432}\u{430}\u{43D} \u{41F}\u{435}\u{442}\u{440}\u{43E}\u{432}")

    assert_equal "", Usernames::Generator.clean("\u{418}\u{432}\u{430}\u{43D}", Usernames.configuration.rules_for)
    names.each { |name| assert_match(/\A[a-z]+_[a-z]+_[0-9a-f]+\z/, name) }
  end

  def test_from_cyrillic_with_any_ascii
    any_ascii = Module.new do
      def self.transliterate(text)
        text.tr("\u{438}\u{432}\u{430}\u{43D}\u{43F}\u{435}\u{442}\u{440}\u{43E}", "ivanpetro")
      end
    end
    Object.const_set(:AnyAscii, any_ascii)

    assert_equal "ivan_petrov",
                 Usernames.generate(from: "\u{418}\u{432}\u{430}\u{43D} \u{41F}\u{435}\u{442}\u{440}\u{43E}\u{432}")
  ensure
    Object.send(:remove_const, :AnyAscii) if defined?(::AnyAscii)
  end

  def test_from_is_cut_at_a_word_boundary
    predictably do
      names = candidates(from: "Pedro Gonzales Armillon", length: 3..15)

      assert_equal %w[pedro_gonzales pedro_10 pedro_100], names.first(3)
    end
  end

  # A single word longer than the budget is skipped, never cut: the batch
  # moves on (to the seed with digits when that fits, to default shapes when not).
  def test_from_is_never_cut_mid_word
    names = predictably { candidates(from: "a" * 40) }

    assert_equal "#{ADJECTIVE}_#{ANIMAL}_10", names.first
    assert(names.none? { |name| name.start_with?("aaa") })
    refute_match(/\Apedrog/, Usernames.generate(from: "Pedro Gonzales", separators: [], length: 3..11))
    assert_equal "maximiliano", Usernames.generate(from: "Maximiliano", length: 3..11)
    refute_equal "maximilia", Usernames.generate(from: "Maximiliano", length: 3..9)
  end

  # Repaired into UTF-8 before anything else, as the normaliser repairs a
  # typed name: no seed can make generation or suggestions raise.
  def test_seeds_in_any_encoding
    assert_equal "javi", Usernames.generate(from: "Javi".encode("UTF-16LE"))
    assert_equal "javi_r", Usernames.generate(from: "Javi R".encode("UTF-16BE"))
    assert_equal "javi", Usernames.generate(from: "Javi\xFF".b)
    assert_equal "jose_garcia", Usernames.generate(from: "Jos\u{E9} Garc\u{ED}a".encode("UTF-16LE"))
    assert_equal "acme", Usernames.generate(from: "info@acme.com".encode("UTF-16LE"))
    assert_equal %w[javi_r javir], Usernames.candidates_for("Javi R".encode("UTF-16LE"), count: 1).first(2)
    assert_predicate Usernames.candidates_for("\xFF\xFE".b, count: 2), :any?
  end

  def test_a_seed_the_rules_refuse_is_skipped
    names = predictably { candidates(from: "Admin") }

    refute(names.any? { |name| name.start_with?("admin") })
    assert_all_allowed names
  end

  def test_fit
    rules = Usernames.configuration.rules_for

    assert_equal "pedro_gonzales", Usernames::Generator.fit("pedro_gonzales_armillon", 14, rules)
    assert_equal "pedro", Usernames::Generator.fit("pedro_gonzales_armillon", 13, rules)
    assert_nil Usernames::Generator.fit("pedro_gonzales", 4, rules), "never mid-word"
    assert_nil Usernames::Generator.fit("maximilianus", 7, rules)
    assert_nil Usernames::Generator.fit("pedro", 0, rules)
    assert_nil Usernames::Generator.fit("", 5, rules)
  end

  # --- custom (§12.3) ------------------------------------------------------------------------------

  def test_a_custom_generator_is_called_with_the_attempt_and_still_checked
    attempts = []
    generator = lambda do |attempt|
      attempts << attempt
      attempt == 1 ? "admin" : "Player#{attempt}"
    end

    assert_equal "player2", Usernames.generate(generator: generator)
    assert_equal (1..20).to_a, attempts
  end

  def test_a_custom_generator_from_the_configuration
    with_config do |config|
      config.generator = ->(attempt) { "guest#{attempt}x" }

      assert_equal "guest1x", Usernames.generate
    end
  end

  def test_custom_word_lists
    predictably do
      assert_equal "tiny_newt_10", Usernames.generate(generator: { adjectives: %w[tiny], nouns: %w[newt] })
      assert_equal "newt_10", Usernames.generate(generator: { adjectives: [], nouns: %w[newt] })
    end
  end

  def test_nothing_to_draw_raises
    error = assert_raises(Usernames::NoFreeNameError) { Usernames.generate(generator: { nouns: [] }) }

    assert_match(/no name these rules allow/, error.message)
    assert_raises(Usernames::NoFreeNameError) { Usernames.generate(length: 29..30) }
  end
end
