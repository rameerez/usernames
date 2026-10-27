# frozen_string_literal: true

module Usernames
  module Offensive
    # One language's bundled data (data/offensive/<locale>.json and its
    # allowlist), compiled once per process into what rules a and b need.
    #
    # Every spelling — terms, variants, exceptions, allowlist entries — is
    # folded exactly as names are (Offensive.fold), so the data stores
    # `fuck` once and `fvck`, `phuck` meet it on the name side. Exemptions
    # are kept both as written and folded: a name's R0 segment `sussex` and
    # its R1 segment `susseks` are the same word.
    class Lexicon
      SEVERE = 4

      # Below this length a severe term must equal a segment: `gc`, `mj`
      # inside a segment would refuse gcastro and mjordan.
      SUBSTRING_MINIMUM = 4

      # One spelling of a term, as folded. `whole` means it is matched only
      # as an entire segment (a short term, or one marked `segment_only`);
      # `digits`, that it has a digit in it (`2g1c`), so it can only ever sit
      # inside a part, never inside a segment.
      Spelling = ::Data.define(:text, :term, :whole, :digits)

      # Spellings by their first SUBSTRING_MINIMUM characters, to find every
      # one inside a string in a single pass over it. A union Regexp of the
      # four hundred spellings did the same job twenty times slower.
      class Index
        def initialize(spellings)
          @by_prefix = spellings.group_by { |spelling| spelling.text[0, SUBSTRING_MINIMUM] }.freeze
        end

        # Whether some spelling occurring in the Whole's text makes the block
        # answer true; the block gets the spelling and where it starts.
        def any?(whole)
          text = whole.text
          whole.grams.each_with_index.any? do |gram, position|
            spellings = @by_prefix[gram]
            spellings&.any? do |spelling|
              text[position, spelling.text.length] == spelling.text && yield(spelling, position)
            end
          end
        end
      end

      class << self
        def for(locale)
          (@lexicons ||= {})[locale.to_sym] ||= new(locale)
        end
      end

      def initialize(locale)
        @allowlist = both_forms(Data.allowlist(locale))
        @exceptions = {}
        @tiers = Hash.new { |tiers, severity| tiers[severity] = {} }
        @equal = {}
        severe = []
        Data.offensive(locale).each { |entry| add(entry, severe) }
        compile(severe)
      end

      # Rule a for this language: a whole-segment spelling that IS a unit, or
      # any severe spelling found in a whole (see #severe_at?).
      def severe?(name, allowed)
        name.units.any? { |unit| whole_severe?(unit, allowed) } ||
          name.wholes.any? do |whole|
            @index.any?(whole) { |spelling, position| severe_at?(whole, spelling, position, allowed) }
          end
      end

      # Rule b: a strong (or, from `minimum` 1, any) spelling that IS one of
      # the name's segments.
      def strong?(name, minimum, allowed)
        table = equal_from(minimum)
        name.units.any? do |unit|
          term = table[unit]
          term && !exempt?(unit, term, allowed)
        end
      end

      private

      def add(entry, severe)
        term = entry.fetch("term")
        severity = entry.fetch("severity")
        @exceptions[term] = both_forms(entry.fetch("exceptions", []))
        [term, *entry.fetch("variants", [])].map { |spelling| Offensive.fold(spelling) }.uniq.each do |text|
          @tiers[severity][text] ||= term
          severe << spelling(text, term, entry) if severity >= SEVERE
        end
      end

      def spelling(text, term, entry)
        whole = text.length < SUBSTRING_MINIMUM || entry["segment_only"] == true
        Spelling.new(text: text, term: term, whole: whole, digits: text.match?(/\d/))
      end

      # Whole-segment spellings are a table looked up by unit; every severe
      # spelling of four letters or more goes in the index a whole is scanned with.
      def compile(severe)
        @whole_severe = severe.select(&:whole).group_by(&:text).freeze
        @index = Index.new(severe.select { |spelling| spelling.text.length >= SUBSTRING_MINIMUM })
        @tiers.default_proc = nil
        @tiers.each_value(&:freeze)
        [@tiers, @exceptions].each(&:freeze)
      end

      # a-1 for the whole-segment spellings: the unit must be the spelling.
      def whole_severe?(unit, allowed)
        @whole_severe[unit]&.any? { |spelling| !exempt?(unit, spelling.term, allowed) }
      end

      # One occurrence of a severe spelling in a whole.
      #
      # a-2 when it straddles a separator (`fu_ck`): refused, with no
      # exemption — such an occurrence lies inside no exempt unit — and
      # without a-1's whole-segment special cases: a separator in the middle
      # of `rape` reads as evasion, so `gr_ape` is refused — a documented
      # trade-off: a real name split exactly there is rarer than the evasion.
      #
      # a-1 otherwise: refused unless the unit it sits in — its segment (or
      # the word of it, between case boundaries), or for a spelling with a
      # digit its part — is exempt. Whole-segment
      # spellings are #whole_severe?'s, not matched as substrings.
      # Spellings under four letters are left out of a-2 as of
      # a-1 (none ships today); across separators they would refuse innocent
      # joins of short segments.
      def severe_at?(whole, spelling, position, allowed)
        return true if whole.straddles?(spelling.text, position)
        return false if spelling.whole

        unit = spelling.digits ? whole.part_at(position) : whole.segment_at(position, spelling.text.length)
        !exempt?(unit, spelling.term, allowed)
      end

      def exempt?(unit, term, allowed)
        @allowlist.include?(unit) || allowed.include?(unit) || @exceptions.fetch(term).include?(unit)
      end

      # { folded spelling => term } over every tier from `minimum` up to
      # strong. Severe spellings are rule a's, which already caught them.
      def equal_from(minimum)
        @equal[minimum] ||= (minimum...SEVERE).each_with_object({}) do |severity, table|
          @tiers.fetch(severity, {}).each { |text, term| table[text] ||= term }
        end.freeze
      end

      def both_forms(words)
        words.each_with_object(Set.new) do |word, set|
          set << word << Offensive.fold(word)
        end.freeze
      end
    end
  end
end
