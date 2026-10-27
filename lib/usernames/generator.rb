# frozen_string_literal: true

require "securerandom"
require "active_support/inflector"

module Usernames
  # Default and seeded names (PRD §12): `quiet_otter_42`, or `jose_garcia`
  # from "José García".
  #
  # Pure: it draws a batch of candidates and keeps those the rules allow; it
  # never asks a database whether one is free. The model helpers take the
  # batch to the database in ONE query, which is why it is a batch: twenty
  # names at once instead of a retry loop of queries.
  #
  # The order inside each draw is fixed (D-19): assemble the name, shorten it
  # to fit, and only then run the full check. Shortening can make a name
  # the check refuses (an all-digit stem, a word cut into something else), and
  # a check run before it would have passed a name that is not the one
  # handed out. Digits always come from SecureRandom, never a counter, so
  # the next name is not guessable from the last.
  module Generator
    # Draws per batch. Every shape, fallback and retry fits inside it.
    DRAWS = 20

    # Local parts that say nothing about the person (PRD §12.2): from
    # info@acme.com the domain label is the better seed.
    GENERIC_LOCAL_PARTS = %w[i me info support admin webmaster hello mail office contact team].freeze

    # Below this maximum length `adjective_noun_42` cannot fit, so the
    # compact shapes take over (as they do with no separators at all).
    COMPACT_BELOW = 10

    # How long a random-letters fallback is, within the length rule.
    RANDOM_LETTERS = 8

    class << self
      # Up to DRAWS distinct names the rules allow, in the order drawn.
      #
      #   Generator.candidates(rules: rules)                  # §12.1 shapes
      #   Generator.candidates(from: "José García", rules: rules)
      #
      # With a seed: the cleaned seed, the seed with two random digits (three
      # times) and with three (twice), then default shapes for the rest of
      # the batch (PRD §12.2).
      # NOTE(p2): the default shapes after a seed count their own attempts
      # from 1, so they start at two digits as an unseeded batch does.
      def candidates(rules:, from: nil)
        base = from.nil? ? "" : clean(from, rules)
        draws = base.empty? ? [] : seeded(base, rules)
        draws += Array.new(DRAWS - draws.size) { |index| shape(index + 1, rules) }
        allowed(draws, rules)
      end

      # One draw of the default shape, or of config.generator when the app
      # set one (called with the attempt number, 1 up). nil when the draw
      # cannot fit the length rule; never checked here.
      def shape(attempt, rules)
        callable = rules.generator.callable
        return callable.call(attempt).to_s if callable

        compact?(rules) ? compact_shape(attempt, rules) : default_shape(attempt, rules)
      end

      # A seed as a name (PRD §12.2 step 1–2): the useful half of an email,
      # normalised, transliterated to ASCII, with every run of characters the
      # rules do not allow turned into the first separator, runs of
      # separators collapsed and the edges trimmed. May be "".
      def clean(seed, rules)
        text = prepare(seed, rules)
        separators = rules.separators
        allowed = "#{rules.lowercase? ? 'a-z' : 'A-Za-z'}0-9#{Regexp.escape(separators.join)}"
        text = text.gsub(/[^#{allowed}]+/, separators.first.to_s)
        return text if separators.empty?

        run = "[#{Regexp.escape(separators.join)}]"
        text.gsub(/#{run}{2,}/) { |separators_run| separators_run[0] }.gsub(/\A#{run}+|#{run}+\z/, "")
      end

      # The words of a seed, whatever the separators: "Javi R" → javi, r.
      def words(seed, rules)
        prepare(seed, rules).split(/[^A-Za-z0-9]+/).reject(&:empty?)
      end

      # `base` cut to at most `budget` characters, at a separator when one
      # falls inside the budget (`pedro_gonzales_armillon` → `pedro_gonzales`),
      # else hard (a single long word). nil when nothing fits.
      # NOTE(p2): a first word longer than the budget is cut mid-word; the
      # PRD only says "at a word boundary", which a single word does not have.
      def fit(base, budget, rules)
        return if budget < 1 || base.empty?
        return base if base.length <= budget

        boundary = rules.separators.empty? ? nil : base.rindex(Regexp.union(rules.separators), budget)
        boundary&.positive? ? base[0, boundary] : base[0, budget]
      end

      # `base` + separator + random digits from `range`, the base shortened
      # first so the whole fits the maximum length.
      def with_digits(base, range, rules)
        separator = rules.separators.first.to_s
        digits = SecureRandom.random_number(range).to_s
        stem = fit(base, rules.length.max - separator.length - digits.length, rules)
        "#{stem}#{separator}#{digits}" if stem
      end

      private

      def seeded(base, rules)
        [fit(base, rules.length.max, rules)] +
          Array.new(3) { with_digits(base, 10..99, rules) } +
          Array.new(2) { with_digits(base, 100..999, rules) }
      end

      # adjective + separator + noun + separator + digits, dropping the
      # adjective when the pair does not fit the budget the digits leave.
      def default_shape(attempt, rules)
        separator = rules.separators.first
        digits = suffix(attempt)
        base = default_base(rules, rules.length.max - separator.length - digits.length)
        "#{base}#{separator}#{digits}" if base
      end

      def default_base(rules, budget)
        noun = pick(rules.generator.nouns)
        return unless noun

        pair = [pick(rules.generator.adjectives), noun].compact.join(rules.separators.first)
        [pair, noun].find { |words| words.length <= budget }
      end

      # For a short maximum or no separators: noun + digits, then the noun
      # cut to the budget (`ott42`), then random letters when not even one
      # letter fits beside the digits (`length: 2..2`).
      def compact_shape(attempt, rules)
        digits = suffix(attempt)
        noun = pick(rules.generator.nouns)
        budget = rules.length.max - digits.length
        name = "#{noun[0, budget]}#{digits}" if noun && budget >= 1
        name && name.length >= rules.length.min ? name : random_letters(rules)
      end

      def compact?(rules)
        rules.separators.empty? || rules.length.max < COMPACT_BELOW
      end

      # Two digits for the first three draws, three for the next two, four
      # for the next three, then six hex characters (PRD §12.1): short names
      # first, and more room as the obvious ones turn out taken.
      def suffix(attempt)
        case attempt
        when 1..3 then SecureRandom.random_number(10..99).to_s
        when 4..5 then SecureRandom.random_number(100..999).to_s
        when 6..8 then SecureRandom.random_number(1000..9999).to_s
        else SecureRandom.hex(3)
        end
      end

      def random_letters(rules)
        length = RANDOM_LETTERS.clamp(rules.length.min, rules.length.max)
        Array.new(length) { ("a".ord + SecureRandom.random_number(26)).chr }.join
      end

      def pick(list)
        list[SecureRandom.random_number(list.size)] if list.any?
      end

      # Normalised, deduplicated and checked — the full check, last.
      def allowed(draws, rules)
        draws.each_with_object([]) do |draw, names|
          next if draw.nil?

          name = rules.normalize(draw)
          names << name unless name.empty? || names.include?(name) || rules.failure_for(name)
        end
      end

      def prepare(seed, rules)
        text = seed.to_s
        text = email_seed(text) if text.include?("@")
        text = transliterate(rules.normalize(text)).delete("?")
        rules.lowercase? ? text.downcase : text
      end

      # The local part, without a +tag, unless it is generic or empty
      # (`@javi` is a handle, not an address): then the domain's first label.
      # NOTE(p2): "the domain label" is read as the first label
      # (`acme` of acme.co.uk); the +tag is dropped (`javi+news`).
      def email_seed(text)
        local, _, domain = text.rpartition("@")
        local = local.split("+", 2).first.to_s.strip
        return local unless local.empty? || GENERIC_LOCAL_PARTS.include?(local.downcase)

        domain.strip.split(".").first.to_s
      end

      # AnyAscii (gem `any_ascii`) when the app has it: it knows Cyrillic,
      # Greek, CJK… Otherwise Active Support's transliteration, which knows
      # Latin accents and writes `?` for the rest — dropped by the caller.
      def transliterate(text)
        defined?(::AnyAscii) ? ::AnyAscii.transliterate(text) : ActiveSupport::Inflector.transliterate(text)
      end
    end
  end
end
