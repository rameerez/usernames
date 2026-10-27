# frozen_string_literal: true

require "test_helper"

# Suggestions for a sign-up form (PRD §13).
class CandidatesTest < UsernamesTestCase
  def candidates_for(seed, count: 5, **)
    Usernames.candidates_for(seed, count: count, **)
  end

  def assert_all_allowed(names, **)
    names.each { |name| assert_predicate Usernames.check(name, **), :ok?, name }
    assert_equal names.uniq, names
  end

  def test_the_seed_first_then_first_name_and_last_initial_then_digits
    names = candidates_for("Javi R")

    assert_equal %w[javi_r javir], names.first(2)
    assert_match(/\Ajavi_r_\d{2}\z/, names[2])
    assert_match(/\Ajavi_r_\d{3}\z/, names[3])
    assert_equal 15, names.size
    assert_all_allowed names
  end

  def test_a_form_for_each_separator_and_none
    names = candidates_for("Pedro Gonzales Armillon", separators: %w[_ . -])

    assert_equal %w[pedro_gonzales_armillon pedro_a pedro.a pedro-a pedroa], names.first(5)
    assert_all_allowed names, separators: %w[_ . -]
  end

  def test_no_separators
    names = candidates_for("Javi R", separators: [])

    assert_equal "javir", names.first
    assert_equal names, names.grep(/\A[a-z0-9]+\z/)
  end

  def test_up_to_three_times_count
    assert_equal 3, candidates_for("Javi R", count: 1).size
    assert_equal 30, candidates_for("Javi R", count: 10).size
  end

  def test_without_a_usable_seed_only_default_shapes
    [nil, "", "???", "\u{418}\u{432}\u{430}\u{43D}"].each do |seed|
      names = candidates_for(seed, count: 2)

      assert_equal 6, names.size, seed.inspect
      names.each { |name| assert_match(/\A[a-z]+_[a-z]+_[0-9a-f]+\z/, name) }
    end
  end

  def test_every_candidate_is_checked
    names = candidates_for("Admin Support")

    refute(names.any? { |name| name.include?("admin") || name.include?("support") })
    assert_all_allowed names
  end

  def test_it_may_return_fewer_and_never_raises_for_running_out
    # Two letters make only 676 names; a thousand and more are asked for.
    names = candidates_for("Javi R", count: 400, length: 2..2)

    assert_operator names.size, :<, 676
    assert_all_allowed names, length: 2..2
    assert_equal [], candidates_for(nil, generator: { nouns: [] })
  end

  def test_count_must_be_a_positive_whole_number
    [0, -1, 2.5, "5", nil].each do |count|
      assert_raises(ArgumentError, count.inspect) { candidates_for("Javi", count: count) }
    end
  end

  def test_per_call_options
    names = candidates_for("Javi R", length: 3..8, case: :preserve)

    assert_equal %w[Javi_R JaviR], names.first(2)
    names.each { |name| assert_operator name.length, :<=, 8 }
  end
end
