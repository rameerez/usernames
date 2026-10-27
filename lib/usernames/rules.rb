# frozen_string_literal: true

require_relative "rules/options"

module Usernames
  # The rules in force for one check: the configuration merged with one
  # model's or one validator call's options, validated once and frozen.
  # Build them with `Usernames.configuration.rules_for(**options)`, which
  # caches them — every check after the first reuses the compiled regexes.
  #
  # The format rules are an ordered list of
  #
  #   [reason, test, browser_source]
  #
  # where `test` is a Regexp (or a lambda) that MATCHES A NAME THAT FAILS,
  # and the first failure wins. Server regexes anchor with \A and \z: `^` and
  # `$` are LINE anchors in Ruby, which is how "validuser\nadmin" gets past
  # the regex everyone copies from Stack Overflow. `browser_source` is the
  # same rule as a JavaScript RegExp source (see #for_browser), or nil for a
  # rule the browser does not hint.
  class Rules
    include Options

    # Every code point Ruby's \p{Space} matches (Unicode White_Space), spelled
    # out for JavaScript, whose \s is a slightly different set (it has U+FEFF
    # and lacks U+0085).
    WHITESPACE_SOURCE = '[\t-\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]'

    # A character outside the allowed set that is a non-ASCII letter (or a
    # combining mark, as in an accent left over from `İ`): the case for the
    # friendlier :username_unicode message.
    NON_ASCII_LETTER = /\A(?=[^\x00-\x7F])[\p{L}\p{M}]\z/

    # Endings that read as a file when dots are enabled, on top of
    # every extension Rails' Mime registry knows: Discourse's
    # CONFUSING_EXTENSIONS, Gitea's reserved patterns, git, and what a web
    # server would execute or serve as a secret.
    FILE_EXTENSIONS = %w[
      js json css htm html xml jpg jpeg png gif bmp ico tif tiff woff
      keys gpg rss atom
      git
      php asp aspx jsp cgi pl py rb sh exe dll bak env
    ].freeze

    # Every extension Rails' Mime registry knows when rules are built,
    # including any the app registered in an initializer. None without
    # Action Dispatch: then there is no Rails router to confuse. Read when
    # the rules are compiled: the first check, or the first after a
    # configuration change.
    def self.rails_extensions
      defined?(Mime::EXTENSION_LOOKUP) ? Mime::EXTENSION_LOOKUP.keys.map(&:to_s) : []
    end

    # Every reason a format rule can give, in the order the rules check:
    # those of rules with every optional format rule switched on (all three
    # separators, a letter first), so a new rule is in it the day it exists.
    def self.format_reasons
      @format_reasons ||= Configuration.new.rules_for(separators: Options::SEPARATORS, first_character: :letter)
        .format_checks.map(&:first).freeze
    end

    attr_reader :format_checks

    def initialize(**options)
      assign(options)
      @format_checks = build_format_checks
      # Left unfrozen on purpose: the reserved and offensive matchers keep
      # what they build from these rules here (see #compiled).
      @compiled = {}
      freeze
    end

    # What a content matcher built from these rules (a reserved set, the
    # offensive exemptions), built on first use and kept for as long as the
    # rules are: Configuration#rules_for caches the rules, so every check
    # after the first reuses it. Two threads may build the same thing once
    # each; both results are equal, so either may win. :nodoc:
    def compiled(name)
      @compiled.fetch(name) { @compiled[name] = yield }
    end

    # Short enough to read in a console or a failing test: the lists can
    # hold a thousand words.
    def inspect
      "#<#{self.class.name} length=#{length} separators=#{separators.inspect} case=#{@case.inspect} " \
        "edge_separators=#{edge_separators} first_character=#{first_character.inspect} " \
        "offensive.severity=#{offensive.severity.inspect}>"
    end

    def lowercase?
      @case == :lowercase
    end

    def normalize(value)
      Normalizer.call(value, @case)
    end

    # What two names are compared by. ASCII-only on purpose: it is exactly
    # what PostgreSQL's lower() does under COLLATE "C", so Ruby and the
    # database agree.
    def comparison_key(canonical)
      canonical.downcase(:ascii)
    end

    # The first rule `value` breaks, as a Usernames::Failure, or nil. Applied
    # to the value AS GIVEN — normalise first if that is what you mean.
    # Structure before content: format, then reserved, then offensive.
    def failure_for(value)
      string = readable(value)
      return failure(:username_characters) unless string

      format_failure(string) || content_failure(string)
    end

    def format_failure(string)
      # `===` is Ruby's "does this match": Regexp#=== and Proc#=== both answer it.
      reason, = format_checks.find { |_reason, test, _source| test === string } # rubocop:disable Style/CaseEquality
      failure(reason) if reason
    end

    # Hints for a form, as [{ rule:, pattern:, message: }] in the current
    # locale. Advisory only: Ruby's strip and JavaScript's trim()
    # disagree on NUL, U+FEFF and U+1680, so the browser approximates
    # normalisation and the server stays the only authority. A pattern
    # MATCHES a name that breaks the rule, and is written in the subset both
    # engines read the same way — no \A, \z, lookbehind or \p{…}. With a
    # `record` and `attribute`, the messages are that model's (Failure#message).
    def for_browser(record = nil, attribute = nil)
      format_checks.filter_map do |reason, _test, source|
        { rule: reason, pattern: source, message: failure(reason).message(record, attribute) } if source
      end
    end

    # The Failure for a format rule, with the interpolations its message needs.
    def failure(reason)
      Failure.new(reason: reason, details: details_for(reason))
    end

    private

    # Valid UTF-8, or nil when the value's own bytes are broken. The
    # validator sees values exactly as assigned, and a regex over invalid
    # bytes raises; such a value has characters that cannot be allowed.
    def readable(value)
      string = value.to_s
      string.encode(Encoding::UTF_8) if string.valid_encoding?
    rescue EncodingError
      nil
    end

    # Reserved words are matched on the comparison key alone; the offensive
    # matcher also reads the case the name was typed in (Offensive.verdict).
    def content_failure(string)
      if (rule = Reserved.verdict(comparison_key(string), self, string))
        Failure.new(reason: :username_reserved, rule: rule)
      elsif (rule = Offensive.verdict(string, self))
        Failure.new(reason: :username_not_allowed, rule: rule)
      end
    end

    def details_for(reason)
      case reason
      when :too_short then { count: length.min }
      when :too_long then { count: length.max }
      when :username_characters then characters_details
      when :username_edges then { edge_separators_phrase: Phrase.any_separator(edge_set) }
      else {}
      end
    end

    # `count` (how many separators) picks the sentence: one finishes the list
    # ("…, numbers and underscores"), more continue it ("…, numbers,
    # underscores and periods"). With none there is no list to finish, so the
    # message is a different translation of the same error type — not a
    # :zero plural, which pluralizers such as rails-i18n's Spanish one ignore.
    # username_characters_without_separators is that translation: the same
    # error type, only worded for no separators.
    def characters_details
      letters = Phrase.letters(@case)
      return { message: :username_characters_without_separators, letters: letters } if separators.empty?

      { count: separators.size, letters: letters, separators_phrase: Phrase.separators(separators) }
    end

    def build_format_checks
      [
        [:username_spaces, /\p{Space}/, WHITESPACE_SOURCE],
        *character_checks,
        [:too_short, ->(string) { string.length < length.min }, "^[\\s\\S]{0,#{length.min - 1}}$"],
        [:too_long, ->(string) { string.length > length.max }, "[\\s\\S]{#{length.max + 1}}"],
        *separator_checks,
        *first_character_checks,
        # Rule 7: a name with no letter in it reads as a number, whatever
        # separators sit between the digits (`231640921`, `123_456`), and a
        # number is an id, not a person. Separators alone never reach this
        # rule: edges and runs refuse them first.
        [:username_digits_only, /\A[^A-Za-z]+\z/, "^[^A-Za-z]+$"],
        *extension_checks
      ].freeze
    end

    # Rule 2. Everything that is not an allowed character fails here —
    # accents, emoji, invisible and bidi characters alike — with the
    # friendlier :username_unicode message when every offender is a
    # non-ASCII letter (`josé`, `иван`). The browser only hints the general
    # rule; the refinement is the same failure in other words.
    def character_checks
      allowed = "#{lowercase? ? 'a-z' : 'A-Za-z'}0-9#{class_of(separators)}"
      disallowed = /[^#{allowed}]/
      only_letters = lambda do |string|
        offenders = string.scan(disallowed)
        offenders.any? && offenders.all?(NON_ASCII_LETTER)
      end

      [[:username_unicode, only_letters, nil], [:username_characters, disallowed, "[^#{allowed}]"]]
    end

    # Rules 4 and 5: no separator at an edge (never a dot, even with
    # edge_separators — "thanks @javi." ends a sentence), no two in a row of
    # any kind (`oliver.__-hjj`).
    def separator_checks
      checks = []
      if edge_set.any?
        edge = class_of(edge_set)
        checks << [:username_edges, /\A[#{edge}]|[#{edge}]\z/, "^[#{edge}]|[#{edge}]$"]
      end
      if separators.any?
        all = class_of(separators)
        checks << [:username_consecutive, /[#{all}]{2}/, "[#{all}]{2}"]
      end
      checks
    end

    # Rule 6. With :alphanumeric any letter or digit may come first, and a
    # separator first is rule 4's business, so there is nothing to check.
    # With :letter the first character must be a letter even when
    # edge_separators allows `_javi`: the stricter reading is the one that
    # matches "must start with a letter".
    def first_character_checks
      return [] unless first_character == :letter

      letters = lowercase? ? "a-z" : "A-Za-z"
      [[:username_first_character, /\A[^#{letters}]/, "^[^#{letters}]"]]
    end

    # Rule 8, only when dots are allowed: `/@john.json` confuses
    # routers, CDNs and crawlers. Not a browser hint: the hints stop at rule 7.
    def extension_checks
      return [] unless separators.include?(".")

      extensions = (Rules.rails_extensions + FILE_EXTENSIONS).uniq.map { |extension| Regexp.escape(extension) }
      [[:username_extension, /\.(?:#{extensions.join('|')})\z/i, nil]]
    end

    def edge_set
      edge_separators ? separators & ["."] : separators
    end

    # The body of a character class holding exactly these separators, written
    # the same way for Ruby and JavaScript (`\.` and `\-` mean themselves in both).
    def class_of(characters)
      characters.map { |character| Regexp.escape(character) }.join
    end
  end
end
