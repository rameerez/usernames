# frozen_string_literal: true

module Usernames
  module Offensive
    # Rule c (PRD §10.3): hate tokens and numbers, from data/offensive/hate.yml.
    #
    # A bare number is not evidence. `88` is a birth year (`mike88`), ham
    # radio's "love and kisses" and a lucky number; `31488210` is a phone
    # fragment. So numbers count only in the forms hate.yml lists — a whole
    # digit run, two parts joined by one separator, or next to a token —
    # while the unambiguous tokens (`heilhitler`, `rahowa`) are refused
    # anywhere. No allowlist or config.offensive.allowed entry lifts these.
    module Hate
      # What may not touch an adjacency token of each kind, before and after it.
      NUMBER_EDGES = ['(?<!\d)', '(?!\d)'].freeze
      WORD_EDGES = ["(?<![a-z])", "(?![a-z])"].freeze

      class << self
        def verdict(name, rules)
          :hate_number if always?(name) || numbers?(name) || whole_token?(name, rules.offensive.languages)
        end

        private

        # Every number rule needs a digit in the name as typed, and the
        # adjacency rule one of its numbers (folding only ever removes digits,
        # so a number in R1 is in R0 too): most names skip them all.
        def numbers?(name)
          key = name.key
          return false unless key.match?(/\d/)

          digit_run?(key) || (adjacent.any? { |number, _tokens| key.include?(number) } && adjacent?(name))
        end

        # A token (all four letters or more) anywhere in a whole: `heil_hitler`
        # is `heilhitler` with its separator removed.
        def always?(name)
          name.wholes.any? { |whole| always.any? { |token| whole.text.include?(token) } }
        end

        # `x1488`, `14_88`, `1.488` — but never inside a longer run.
        # NOTE(p2): "two parts joined by one separator" is read as the number
        # split at any point (14_88, 1_488, 148_8), not only in the middle.
        def digit_run?(key)
          key.scan(/\d+/).any? { |run| digit_runs.include?(run) } || joined_runs&.match?(key)
        end

        # `88` beside heil/hh/hitler… with or without one separator between
        # (`hh88`, `heil_88`, `88hitler`), in either form (`h3il88` is
        # `heil88` folded). The neighbour must be a whole run: `88` after
        # `ahh` is not after `hh`.
        # NOTE(p2): number tokens (`14`, `18`, `88`) are whole digit runs, so
        # `14_88` counts but `1888` (a year) does not.
        def adjacent?(name)
          name.forms.any? { |form| adjacency.match?(form) }
        end

        # `kkk` and `zog` only as a whole segment, and only in the languages
        # that list them (kkk is laughter in Brazilian Portuguese).
        def whole_token?(name, languages)
          languages.any? do |locale|
            tokens = whole_tokens.fetch(locale.to_s, [])
            tokens.any? && name.segments.any? { |segment| tokens.include?(segment) }
          end
        end

        def always
          @always ||= rules.fetch("always", []).map { |token| Offensive.fold(token.to_s) }.uniq.freeze
        end

        def digit_runs
          @digit_runs ||= rules.fetch("digit_runs", []).map(&:to_s).freeze
        end

        def joined_runs
          return @joined_runs if defined?(@joined_runs)

          splits = digit_runs.flat_map do |run|
            (1...run.length).map { |at| "#{run[0, at]}[_.\\-]#{run[at..]}" }
          end
          @joined_runs = splits.empty? ? nil : /(?<!\d)(?:#{splits.join('|')})(?!\d)/
        end

        def adjacent
          @adjacent ||= rules.fetch("adjacent", {}).to_h do |number, tokens|
            [number.to_s, tokens.map(&:to_s).freeze]
          end.freeze
        end

        # One Regexp for every number and its tokens, each side: the token a
        # whole run (nothing of its own kind touching it), then at most one
        # separator, then the number as a whole digit run — or the mirror
        # image. A number token always needs its separator: `1488` is one run.
        def adjacency
          @adjacency ||= begin
            sides = adjacent.flat_map do |number, tokens|
              numbers, words = tokens.partition { |token| token.match?(/\A\d+\z/) }
              beside(number, numbers, NUMBER_EDGES, "[_.\\-]") + beside(number, words, WORD_EDGES, "[_.\\-]?")
            end
            sides.empty? ? /(?!)/ : Regexp.new(sides.join("|"))
          end
        end

        # `tokens` before `number` and after it, as Regexp sources.
        def beside(number, tokens, edges, joint)
          return [] if tokens.empty?

          group = "(?:#{tokens.map { |token| Regexp.escape(token) }.join('|')})"
          ["#{edges[0]}#{group}#{joint}#{number}(?!\\d)", "(?<!\\d)#{number}#{joint}#{group}#{edges[1]}"]
        end

        def whole_tokens
          @whole_tokens ||= rules.fetch("whole_token", {}).to_h do |locale, tokens|
            [locale.to_s, Array(tokens).map(&:to_s).freeze]
          end.freeze
        end

        def rules
          Data.hate
        end
      end
    end
  end
end
