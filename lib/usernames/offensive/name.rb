# frozen_string_literal: true

module Usernames
  module Offensive
    # One name, read every way the offensive matcher reads it. Built once per check.
    #
    #   forms        R0 (the key) and R1 (the key folded)
    #   segments     what sits between separators and digit runs, in either form
    #   digit_parts  what sits between separators only, where a digit keeps it
    #                from being a segment — the unit a spelling that itself has a
    #                digit in it (`2g1c`) is read against; segments never hold a
    #                digit, so without these such a spelling could never match
    #   wholes       each form with its separators removed (see Whole)
    #   joins        runs of adjacent words a case boundary split (see below)
    #
    # A name stored with its typed case (`case: :preserve`) also splits where
    # a lowercase letter meets a capital, and before the last capital of a
    # run that a lowercase letter follows: `ShitheadBob` is the segments
    # shitheadbob, shithead and bob, `SHITHEADBob` the same, and
    # `ScunthorpeUnited` is scunthorpeunited, scunthorpe and united. The
    # capital is the only word boundary such a name has, and the person
    # typed it. The glued segment stays a segment, and the whole is
    # unchanged.
    #
    # Capitals also cut inside a word as often as between words
    # (`ShitHeadBob`), so the strong terms, matched by equality, are also
    # compared with every run of adjacent words of one segment: shithead,
    # headbob. A run spans at most JOIN_WORDS words. A word a capital does
    # not end (`XxShitHeadxX` reads Xx, Shit, Headx, X) makes no join that
    # is a word: a known limit.
    #
    # Segments come from BOTH forms: `adm1n` is the segments adm, n as typed
    # and admin folded, and `shithead1` keeps shithead as typed where folded it
    # reads shitheadi.
    class Name
      attr_reader :key, :forms, :wholes, :segments, :digit_parts, :joins

      # Where a lowercase letter meets a capital (`tB`), and where a run of
      # capitals gives its last one to the word it starts (`DBo`).
      CASE_BOUNDARY = /(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])/

      # The most words one join of case-split words spans.
      JOIN_WORDS = 8

      # `key` is the comparison key; `canonical`, the name as stored, which
      # differs from it only in case.
      def initialize(key, canonical = key)
        @key = key
        @forms = [key, Offensive.fold(key)].uniq
        boundaries = case_boundaries(canonical)
        @wholes = [
          Whole.new(key, boundaries: boundaries),
          Whole.new(Reserved.leet(key), folded: true, boundaries: boundaries)
        ].uniq do |whole|
          [whole.text, whole.segments]
        end
        @segments = @wholes.flat_map(&:segments).uniq
        @digit_parts = @wholes.flat_map(&:parts).grep(/\d/).uniq
        @joins = (@wholes.flat_map(&:joins) - @segments).uniq
      end

      # What a whole-segment rule compares against: every segment, and every
      # part a digit keeps from being one.
      def units
        segments + digit_parts
      end

      private

      # The positions of the key where `canonical` changes from a lowercase
      # letter to a capital. Positions carry over: the key is `canonical`
      # with its ASCII letters lowercased, and the digit fold maps one
      # character to one.
      def case_boundaries(canonical)
        return [].freeze if canonical == key

        positions = []
        canonical.scan(CASE_BOUNDARY) { positions << Regexp.last_match.begin(0) }
        positions.freeze
      end
    end

    # A form with its separators removed (`f.u.c.k` → `fuck`), remembering
    # for every character which parts (between separators) and which segment
    # (between separators and digit runs) it came from. One pass over this
    # text finds every severe spelling for rules a-1 and a-2 at once: an
    # occurrence that straddles two parts is a-2's evasion, and one inside a
    # part lies inside exactly one segment (a spelling without digits cannot
    # cover a digit), which is a-1's unit.
    #
    # The folded whole (`folded: true`, built from the digit-folded key) is
    # rewritten twice: each part and segment on its own, and the joined text
    # again once the separators are gone — so a rewrite split by a separator
    # (`p_huck`, `f_vck`, `fuuu_uuck`) still folds. A character a rewrite
    # makes from two parts (the `f` of `p_huck`) remembers both, so whatever
    # covers it straddles them, and an exemption never applies there.
    #
    # Case boundaries (see Name) cut a segment into words without making
    # them parts: an occurrence across one (`ScunThorpe`) is still inside
    # one segment, the glued one, and is judged by it. One that lies inside
    # a single word is judged by that word, so `ScunthorpeUnited` is exempt
    # where `scunthorpeunited` is not.
    class Whole
      # What sits between separators.
      PART = /[^_.-]+/

      attr_reader :text, :parts, :segments, :joins

      def initialize(form, folded: false, boundaries: [])
        @folded = folded
        @boundaries = boundaries
        @text = +""
        @parts = []
        @segments = []
        @joins = []
        @origins = [] # [first part, last part, segment, word] per character of @text
        form.scan(PART) { add(Regexp.last_match[0], Regexp.last_match.begin(0)) }
        rewrite_text if folded
        @text.freeze
      end

      # Every substring of Lexicon::SUBSTRING_MINIMUM characters, in order:
      # what each language's Lexicon::Index looks up, cut once per name.
      def grams
        size = Lexicon::SUBSTRING_MINIMUM
        @grams ||= (0..(text.length - size)).map { |position| text[position, size] }.freeze
      end

      # Whether `spelling`, found at `position` of the text, straddles a separator.
      def straddles?(spelling, position)
        @origins[position][0] != @origins[position + spelling.length - 1][1]
      end

      def part_at(position)
        @parts[@origins[position][0]]
      end

      # The segment that `length` characters from `position` lie in: the word
      # between case boundaries when they fit in one, the segment otherwise,
      # or nil on a digit.
      def segment_at(position, length = 1)
        _first, _last, segment, word = @origins[position]
        return @segments[word] if word && word == @origins[position + length - 1][3]

        @segments[segment] if segment
      end

      private

      # `offset`: where the part starts in the form, to place case boundaries.
      def add(part, offset)
        part_index = @parts.size
        @parts << folded(part)
        part.scan(/\d+|\D+/) do |run|
          start = offset + Regexp.last_match.begin(0)
          if run.getbyte(0).between?(48, 57)
            run.length.times { @origins << [part_index, part_index, nil, nil] }
          else
            add_segment(run, start, part_index)
          end
          @text << run
        end
      end

      # A run of letters: one segment, and one more for each word in it when
      # case boundaries cut it.
      def add_segment(run, start, part_index)
        segment = @segments.size
        @segments << folded(run)
        words = words_in(run, start)
        if words.one?
          run.length.times { @origins << [part_index, part_index, segment, nil] }
        else
          words.each do |word|
            @segments << folded(word)
            index = @segments.size - 1
            word.length.times { @origins << [part_index, part_index, segment, index] }
          end
          add_joins(words)
        end
      end

      # Every run of two or more adjacent words short of the whole segment,
      # each folded as one text: a rewrite can span the boundary (`PHuck`).
      def add_joins(words)
        (0...words.size).each do |from|
          ((from + 2)..[words.size, from + Name::JOIN_WORDS].min).each do |to|
            @joins << folded(words[from...to].join) unless from.zero? && to == words.size
          end
        end
      end

      # `run` (which starts at `start` in the form) cut at the case boundaries inside it.
      def words_in(run, start)
        return [run] if @boundaries.empty?

        cuts = @boundaries.filter_map { |at| at - start if at > start && at < start + run.length }
        [0, *cuts].zip([*cuts, run.length]).map { |from, to| run[from...to] }
      end

      def folded(text)
        @folded ? Offensive.rewrite(text) : text
      end

      # Offensive.rewrite over the joined text, carrying every character's origins along.
      def rewrite_text
        return if Offensive.rewrite(@text) == @text # most names: nothing to rewrite

        characters = @text.chars.zip(@origins)
        Offensive.rewrites.each { |from, to| characters = replace(characters, from, to) }
        characters = cut_stretches(characters)
        @text = characters.map(&:first).join
        @origins = characters.map(&:last)
      end

      # `from` → `to` left to right, as String#gsub does; each new character
      # comes from every part the replaced ones came from.
      def replace(characters, from, to)
        result = []
        index = 0
        while index < characters.size
          window = characters[index, from.length]
          if window.map(&:first).join == from
            origin = merged(window.map(&:last))
            to.each_char { |character| result << [character, origin] }
            index += from.length
          else
            result << characters[index]
            index += 1
          end
        end
        result
      end

      # A run of three or more of one letter becomes two; the second stands
      # for the rest of the run, wherever it came from.
      def cut_stretches(characters)
        characters.chunk_while { |a, b| a.first == b.first }.flat_map do |run|
          next run if run.size < 3 || !run.first.first.match?(/[a-z]/)

          [run.first, [run[1].first, merged(run[1..].map(&:last))]]
        end
      end

      # A character made from several keeps the first one's segment, and a
      # word only when they all came from the same one.
      def merged(origins)
        words = origins.map(&:last).uniq
        [origins.map(&:first).min, origins.map { |origin| origin[1] }.max, origins.first[2],
         words.size == 1 ? words.first : nil]
      end
    end
  end
end
