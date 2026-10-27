# frozen_string_literal: true

module Usernames
  # A piece of an error message that depends on the rules in force and on the
  # locale: "underscores, periods and dashes", "an underscore or a period",
  # "lowercase letters".
  #
  # Translated when the message is READ, not when the error is added. Active
  # Model keeps an error's options and builds its message on every read, so a
  # record validated in English and rendered inside `I18n.with_locale(:es)`
  # (a mailer, a background job) must not carry an English fragment into a
  # Spanish sentence. I18n calls any interpolation value that responds to
  # #call; everything else (errors.details, JSON, inspect) sees the text.
  class Phrase
    SEPARATOR_NAMES = { "_" => :underscore, "." => :period, "-" => :dash }.freeze
    SCOPE = %i[usernames separators].freeze

    class << self
      # "underscores", "underscores and periods", "underscores, periods and
      # dashes" — every separator allowed, in the order they were configured.
      def separators(separators)
        new { join(separators, form: :plural, connector: :and) }
      end

      # "an underscore", "an underscore or a period" — any one of them.
      def any_separator(separators)
        new { join(separators, form: :singular, connector: :or) }
      end

      # "lowercase letters" or, when the typed case is kept, "letters".
      def letters(case_mode)
        new { I18n.t(case_mode == :lowercase ? :lowercase : :any_case, scope: %i[usernames letters]) }
      end

      # The list sentence itself, in the current locale. Not to_sentence:
      # Rails' English connectors carry an Oxford comma, and these sentences
      # are written without one in all three shipped languages.
      def join(separators, form:, connector:)
        words = separators.map { |separator| I18n.t(form, scope: [*SCOPE, SEPARATOR_NAMES.fetch(separator)]) }
        return words.join if words.size < 2

        connectors = [*SCOPE, :connectors]
        [words[0..-2].join(I18n.t(:words, scope: connectors)), words.last].join(I18n.t(connector, scope: connectors))
      end
    end

    def initialize(&translate)
      @translate = translate
    end

    def to_s
      @translate.call.to_s
    end

    # What I18n calls while interpolating.
    def call(*)
      to_s
    end

    def as_json(*)
      to_s
    end

    def inspect
      to_s.inspect
    end
  end
end
