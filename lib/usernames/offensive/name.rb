# frozen_string_literal: true

module Usernames
  module Offensive
    # One name, read every way PRD §10.2 reads it. Built once per check.
    #
    #   forms        R0 (the key) and R1 (the key folded)
    #   segments     what sits between separators and digit runs, in either form
    #   digit_parts  what sits between separators only, where a digit keeps it
    #                from being a segment — the unit a spelling that itself has a
    #                digit in it (`2g1c`) is read against
    #   wholes       each form with its separators removed (see Whole)
    #
    # NOTE(p2): digit_parts are not in PRD §10.2. Its segments never hold a
    # digit, so without them the bundled spellings that have one (`2g1c`,
    # `masturb8`) could never match at all.
    #
    # Segments from BOTH forms (R2-5): `adm1n` is the segments adm, n in R0
    # and admin in R1, and `shithead1` keeps shithead in R0 where R1 reads
    # shitheadi.
    class Name
      PART_BOUNDARY = /[_.-]+/

      attr_reader :key, :forms, :wholes, :segments, :digit_parts

      def initialize(key)
        @key = key
        @forms = [key, Offensive.fold(key)].uniq
        @wholes = @forms.map { |form| Whole.new(form) }
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
    # for every character which part (between separators) and which segment
    # (between separators and digit runs) it came from. One pass over this
    # text finds every severe spelling for rules a-1 and a-2 at once: an
    # occurrence that straddles two parts is a-2's evasion, and one inside a
    # part lies inside exactly one segment (a spelling without digits cannot
    # cover a digit), which is a-1's unit.
    class Whole
      attr_reader :text, :parts, :segments

      def initialize(form)
        @text = +""
        @parts = []
        @segments = []
        @part_of = []
        @segment_of = []
        form.split(Name::PART_BOUNDARY).each { |part| add(part) unless part.empty? }
        @text.freeze
      end

      # Every substring of Lexicon::SUBSTRING_MINIMUM characters, in order:
      # what each language's Lexicon::Index looks up, cut once per name.
      def grams
        size = Lexicon::SUBSTRING_MINIMUM
        @grams ||= (0..(text.length - size)).map { |position| text[position, size] }.freeze
      end

      def single_part?
        @parts.size < 2
      end

      # Whether `spelling`, found at `position` of the text, straddles a separator.
      def straddles?(spelling, position)
        @part_of[position] != @part_of[position + spelling.length - 1]
      end

      def part_at(position)
        @parts[@part_of[position]]
      end

      # The segment at `position`, or nil on a digit.
      def segment_at(position)
        index = @segment_of[position]
        @segments[index] if index
      end

      private

      def add(part)
        @part_of.fill(@parts.size, @text.length, part.length)
        @parts << part
        part.scan(/\d+|\D+/) do |run|
          digits = run.getbyte(0).between?(48, 57)
          @segment_of.fill(digits ? nil : @segments.size, @text.length, run.length)
          @segments << run unless digits
          @text << run
        end
      end
    end
  end
end
