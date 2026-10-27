# frozen_string_literal: true

require "test_helper"
require "etc"
require "json"

# The generator's vocabulary and its CI guarantee: no adjective +
# animal pair, at any digit shape the generator draws, is a name the gem
# itself would refuse.
class WordsTest < UsernamesTestCase
  ADJECTIVES = Usernames::Words::ADJECTIVES
  ANIMALS = Usernames::Words::ANIMALS

  # One suffix per shape (two, three, four digits, six hex characters).
  # `88` stands for every two-digit number: the only one a word could make a
  # hate number of, which #test_no_word_is_a_hate_number_token rules out.
  # Digits that leet-fold into letters are the per-draw check's business, at
  # generation time, not the word lists'.
  SHAPES = %w[88 100 1000 2b9f6d].freeze

  def test_the_lists
    assert_equal Usernames::Data.adjectives, ADJECTIVES
    assert_equal Usernames::Data.nouns, ANIMALS
    assert_predicate ADJECTIVES, :frozen?
    assert_predicate ANIMALS, :frozen?
    assert_operator ADJECTIVES.size, :>, 300
    assert_operator ANIMALS.size, :>, 200
    assert_equal ADJECTIVES, Usernames.configuration.generator.adjectives
  end

  def test_every_pair_at_every_digit_shape_passes_check_at_strong
    rules = Usernames.configuration.rules_for(offensive: { severity: :strong })
    rules.failure_for("warm_up_88")

    refused = sweep(ADJECTIVES.product(ANIMALS)) do |adjective, animal|
      SHAPES.filter_map do |digits|
        name = "#{adjective}_#{animal}_#{digits}"
        failure = rules.failure_for(name)
        "#{name} (#{failure.reason} #{failure.rule})" if failure
      end
    end

    assert_empty refused
  end

  # The shapes the generator falls back to: the noun alone, with or without
  # a separator.
  def test_every_animal_alone_passes_too
    refused = ANIMALS.product(SHAPES, ["_", ""]).filter_map do |animal, digits, separator|
      name = "#{animal}#{separator}#{digits}"
      name unless Usernames.allowed?(name, offensive: { severity: :strong })
    end

    assert_empty refused
  end

  def test_no_word_is_a_hate_number_token
    tokens = Usernames::Data.hate.fetch("adjacent").values.flatten

    assert_empty (ADJECTIVES + ANIMALS) & tokens
  end

  private

  # items.flat_map(&block), across forked workers where the platform can
  # fork: the full sweep is ~370,000 checks. A worker hands its results back
  # through a pipe (as JSON: they are strings) and leaves with exit!, so
  # Minitest and SimpleCov report once, from this process.
  def sweep(items, &block)
    workers = Process.respond_to?(:fork) ? Etc.nprocessors.clamp(1, 8) : 1
    return items.flat_map(&block) if workers == 1

    running = items.each_slice((items.size / workers.to_f).ceil).map { |slice| start_worker(slice, &block) }
    running.flat_map { |pid, reader| finish_worker(pid, reader) }
  end

  def start_worker(slice, &block)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(JSON.generate(slice.flat_map(&block)))
      writer.close
      exit!(0)
    end
    writer.close
    [pid, reader]
  end

  def finish_worker(pid, reader)
    JSON.parse(reader.read)
  ensure
    reader.close
    Process.wait(pid)
  end
end
