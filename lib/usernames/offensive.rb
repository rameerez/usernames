# frozen_string_literal: true

require_relative "offensive/name"
require_relative "offensive/lexicon"
require_relative "offensive/hate"
require_relative "adapters/moderate"

module Usernames
  # Offensive words: bundled terms in severity tiers per language,
  # hate-number rules and optional adapters (`moderate`, any callable).
  #
  # The whole design is a fight between two failure modes. Match too
  # little and `f.u.c.k` or `sh1thead_bob` gets through; match substrings
  # naively and Scunthorpe, Penistone, `grape` and `therapist` cannot sign
  # up. So each tier is matched as narrowly as its words allow:
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

    # A letter repeated three times or more: a stretched spelling (`fuuuuuck`).
    STRETCH = /([a-z])\1{2,}/

    class << self
      # The kind of match — :severe, :strong, :hate_number or :adapter — or nil
      # when the name is fine. `canonical` is a name as stored that passed
      # every format rule and is not reserved: the words are matched on its
      # comparison key, split also where its case changes (see Name), and
      # adapters get it as it is; `rules` is the
      # Usernames::Rules in force (rules.offensive carries severity, languages,
      # allowed and adapters; rules.on_adapter_failure what a raising adapter means).
      #
      # `:off` turns off everything the gem bundles, hate rules included;
      # adapters run in every mode, because an app that configured one asked
      # for it explicitly.
      def verdict(canonical, rules)
        severity = rules.offensive.severity
        unless severity == :off
          name = Name.new(rules.comparison_key(canonical), canonical)
          rule = lexical(name, rules, severity) || Hate.verdict(name, rules)
          return rule if rule
        end

        adapter_verdict(canonical, rules)
      end

      # A name's folded form (R1): the digit folds (`sh1t` → `shit`), then
      # #rewrite. Terms are folded the same way when they are loaded, so
      # `phuck` in the data and `fuck` typed meet.
      def fold(string)
        rewrite(Reserved.leet(string))
      end

      # The rewrites of data/offensive/leet.yml in order — `vv`→`w`, `v`→`u`,
      # `ph`→`f`, `x`→`ks` — then every run of three or more of one letter cut
      # to two (`fuuuuuck` → `fuuck`). Not doubles: `ass` and `book` stay.
      def rewrite(string)
        rewritten = rewrites.reduce(string) do |text, (from, to)|
          text.include?(from) ? text.gsub(from, to) : text
        end
        rewritten.gsub(STRETCH, '\1\1')
      end

      # [[from, to], …]: the offensive-only rewrites of data/offensive/leet.yml, in order.
      def rewrites
        @rewrites ||= Data.leet.fetch("offensive_only").to_a.freeze
      end

      private

      # Rules a and b over every enabled language: any language's rejection
      # rejects, and a severe verdict outranks a strong one.
      def lexical(name, rules, severity)
        allowed = allowed_for(rules)
        # A name the app allowed in so many words is exempt as a whole. The
        # whole name is matched exactly, so joining segments still cannot
        # manufacture an exemption.
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

      def adapter_verdict(canonical, rules)
        :adapter if rules.offensive.adapters.any? { |adapter| flagged?(adapter, canonical, rules) }
      end

      # A raising adapter (a network blip, a bug) follows on_adapter_failure:
      # :allow (the default: an optional adapter fails open) skips
      # it, :reject refuses the name. Either way it is logged, so a broken
      # adapter is not silently a no-op forever.
      # Adapters receive the name as stored, typed case and all: a capital is
      # a word boundary a text classifier can use (see Adapters::Moderate).
      def flagged?(adapter, canonical, rules)
        callable = adapter == :moderate ? Adapters::Moderate : adapter
        callable.call(canonical) ? true : false
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
    end
  end
end
