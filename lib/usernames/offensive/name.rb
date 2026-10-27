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
    #
    # Segments come from BOTH forms: `adm1n` is the segments adm, n as typed
    # and admin folded, and `shithead1` keeps shithead as typed where folded it
    # reads shitheadi.
    class Name
      PART_BOUNDARY = /[_.-]+/

      attr_reader :key, :forms, :wholes, :segments, :digit_parts

      def initialize(key)
        @key = key
        @forms = [key, Offensive.fold(key)].uniq
        @wholes = [Whole.new(key), Whole.new(Reserved.leet(key), folded: true)].uniq do |whole|
          [whole.text, whole.segments]
        end
        @segments = @wholes.flat_map(&:segments).uniq
        @digit_parts = @wholes.flat_map(&:parts).grep(/\d/).uniq
      end

      # What a whole-segment rule compares against: every segment, and every
      # part a digit keeps from being one.
      def units
        segments + digit_parts
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
    class Whole
      attr_reader :text, :parts, :segments

      def initialize(form, folded: false)
        @folded = folded
        @text = +""
        @parts = []
        @segments = []
        @origins = [] # [first part, last part, segment] per character of @text
        form.split(Name::PART_BOUNDARY).each { |part| add(part) unless part.empty? }
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

      # The segment at `position`, or nil on a digit.
      def segment_at(position)
        index = @origins[position][2]
        @segments[index] if index
      end

      private

      def add(part)
        part_index = @parts.size
        @parts << (@folded ? Offensive.rewrite(part) : part)
        part.scan(/\d+|\D+/) do |run|
          digits = run.getbyte(0).between?(48, 57)
          segment = digits ? nil : @segments.size
          @segments << (@folded ? Offensive.rewrite(run) : run) unless digits
          run.length.times { @origins << [part_index, part_index, segment] }
          @text << run
        end
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

      def merged(origins)
        [origins.map(&:first).min, origins.map { |origin| origin[1] }.max, origins.first[2]]
      end
    end
  end
end
