# frozen_string_literal: true

module Usernames
  # Suggestions for a sign-up form: `Usernames.candidates_for("Javi R", count: 5)`.
  #
  # Up to 3 × count allowed names, best first: the seed itself, first name +
  # last initial, the seed with a few random digits, then default shapes.
  # Three times as many as asked for because the caller still subtracts
  # the taken ones (one query) and should usually have `count` left.
  module Candidates
    class << self
      def for(seed, count:, rules:)
        unless count.is_a?(Integer) && count.positive?
          raise ArgumentError, "count must be a positive whole number (got #{count.inspect})"
        end

        limit = 3 * count
        names = []
        seeded(seed, count, rules).each { |draw| add(names, draw, limit, rules) }
        # Default shapes for the rest, within a bounded number of draws: a
        # tight rule set may allow few of them, and this must still end.
        [limit * 2, Generator::DRAWS].max.times do |index|
          break if names.size >= limit

          add(names, Generator.shape(index + 1, rules), limit, rules)
        end
        names
      end

      private

      # The cleaned seed; first name + last initial, with each configured
      # separator and with none (`javi_r`, `javir`); then the seed with two
      # and three random digits, `count` of them in turn.
      def seeded(seed, count, rules)
        return [] if seed.nil?

        base = Generator.clean(seed, rules)
        return [] if base.empty?

        max = rules.length.max
        [Generator.fit(base, max, rules), *initials(Generator.words(seed, rules), rules)] +
          Array.new(count) { |index| Generator.with_digits(base, index.even? ? 10..99 : 100..999, rules) }
      end

      def initials(words, rules)
        return [] if words.size < 2

        initial = words.last[0]
        (rules.separators + [""]).filter_map do |separator|
          first = Generator.fit(words.first, rules.length.max - separator.length - initial.length, rules)
          "#{first}#{separator}#{initial}" if first
        end
      end

      def add(names, draw, limit, rules)
        return if draw.nil? || names.size >= limit

        name = rules.normalize(draw)
        names << name unless name.empty? || names.include?(name) || rules.failure_for(name)
      end
    end
  end
end
