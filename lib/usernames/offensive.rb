# frozen_string_literal: true

require_relative "offensive/name"
require_relative "offensive/lexicon"
require_relative "offensive/hate"
require_relative "adapters/moderate"

module Usernames
  # Offensive words (PRD §10): bundled terms in severity tiers per language,
  # hate-number rules and optional adapters (`moderate`, any callable).
  #
  # The whole design is a fight between two failure modes. Match too
  # little and `f.u.c.k` or `sh1thead_bob` gets through; match substrings
  # naively and Scunthorpe, Penistone, `grape` and `therapist` cannot sign
  # up. So each tier is matched as narrowly as its words allow (PRD §10.2):
  #
  #   a-1  severe (tier 4): inside any segment that is not exempt; short
  #        terms and `segment_only` ones must BE the segment (grape, Shōta)
  #   a-2  severe, across separators: in the name with separators removed,
  #        but only where the word straddles them (`fu_ck`, `gr_ape`)
  #   b    strong (tier 3; tiers 1–2 too under :mild): a whole segment
  #   c    hate numbers and tokens (Offensive::Hate)
  #   d    adapters
  #
  # Exemptions (the bundled allowlist, config.offensive.allowed, a term's own
  # exceptions) are whole SEGMENTS, never the joined name: otherwise
  # `scunt_horpe` would join into the exempt `scunthorpe`. They lift a–b
  # only; hate rules and adapters are authoritative.
  module Offensive
    # Which tiers rule b looks at, per severity mode (nil: rule b is off).
    EQUAL_FROM = { severe: nil, strong: 3, mild: 1 }.freeze

    class << self
      # The kind of match — :severe, :strong, :hate_number or :adapter — or nil
      # when the name is fine. `key` is Usernames.comparison_key of a name that
      # passed every format rule and is not reserved; `rules` is the
      # Usernames::Rules in force (rules.offensive carries severity, languages,
      # allowed and adapters; rules.on_adapter_failure what a raising adapter means).
      #
      # `:off` turns off everything the gem bundles, hate rules included;
      # adapters run in every mode, because an app that configured one asked
      # for it explicitly.
      def verdict(key, rules)
        severity = rules.offensive.severity
        unless severity == :off
          name = Name.new(key)
          rule = lexical(name, rules, severity) || Hate.verdict(name, rules)
          return rule if rule
        end

        adapter_verdict(key, rules)
      end

      # R1 of PRD §10.2: the digit folds (`sh1t` → `shit`), then `vv`→`w`,
      # `ph`→`f`, `x`→`ks`, in that order. Terms are folded the same way when
      # they are loaded, so `phuck` in the data and `fuck` typed meet.
      def fold(string)
        rewrites.reduce(Reserved.leet(string)) do |folded, (from, to)|
          folded.include?(from) ? folded.gsub(from, to) : folded
        end
      end

      private

      # Rules a and b over every enabled language: any language's rejection
      # rejects, and a severe verdict outranks a strong one.
      def lexical(name, rules, severity)
        allowed = allowed_for(rules)
        # A name the app allowed in so many words is exempt as a whole.
        # NOTE(p2): PRD §6.6 calls offensive.allowed a "whole-name/whole-segment"
        # exemption; the whole name is matched exactly, so joining segments
        # still cannot manufacture one.
        return if allowed.include?(name.key)

        lexicons = rules.offensive.languages.map { |locale| Lexicon.for(locale) }
        return :severe if lexicons.any? { |lexicon| lexicon.severe?(name, allowed) }

        minimum = EQUAL_FROM.fetch(severity)
        :strong if minimum && lexicons.any? { |lexicon| lexicon.strong?(name, minimum, allowed) }
      end

      # config.offensive.allowed, as typed and folded (an entry `sussex` must
      # exempt the folded segment `susseks` too).
      def allowed_for(rules)
        rules.compiled(:offensive_allowed) do
          rules.offensive.allowed.each_with_object(Set.new) do |word, set|
            key = word.strip.downcase(:ascii)
            set << key << fold(key)
          end.freeze
        end
      end

      def adapter_verdict(key, rules)
        :adapter if rules.offensive.adapters.any? { |adapter| flagged?(adapter, key, rules) }
      end

      # A raising adapter (a network blip, a bug) follows on_adapter_failure:
      # :allow (the default — PRD §4.5, optional adapters fail open) skips
      # it, :reject refuses the name. Either way it is logged, so a broken
      # adapter is not silently a no-op forever.
      # NOTE(p2): adapters receive the comparison key (the name lowercased),
      # since content verdicts are given only the key.
      def flagged?(adapter, key, rules)
        callable = adapter == :moderate ? Adapters::Moderate : adapter
        callable.call(key) ? true : false
      rescue StandardError => e
        reject = rules.on_adapter_failure == :reject
        log("[usernames] offensive adapter #{adapter.inspect} raised #{e.class}: #{e.message} " \
            "(#{reject ? 'name rejected' : 'skipped'}, on_adapter_failure: #{rules.on_adapter_failure.inspect})")
        reject
      end

      def log(message)
        logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
        logger ? logger.warn(message) : warn(message)
      end

      def rewrites
        @rewrites ||= Data.leet.fetch("offensive_only").to_a.freeze
      end
    end
  end
end
