# frozen_string_literal: true

module Usernames
  class Rules
    # Every option the gem takes, checked once when a Rules is built — so an
    # initializer typo (`config.case = :lower`, `length: 3`) fails at boot
    # with the bad value named, instead of quietly meaning something else on
    # the day somebody signs up.
    module Options
      NAMES = %i[
        length separators edge_separators case first_character reserve_routes app_name
        reserved forbidden allowed reserved_if offensive on_adapter_failure generator unique_index
      ].freeze

      OFFENSIVE_NAMES = %i[severity languages allowed adapters].freeze
      GENERATOR_NAMES = %i[adjectives nouns callable].freeze

      SEPARATORS = %w[_ . -].freeze
      CASES = %i[lowercase preserve].freeze
      FIRST_CHARACTERS = %i[alphanumeric letter].freeze
      SEVERITIES = %i[severe strong mild off].freeze
      ADAPTER_FAILURE_MODES = %i[allow reject].freeze

      OffensiveSettings = ::Data.define(*OFFENSIVE_NAMES)
      GeneratorSettings = ::Data.define(*GENERATOR_NAMES)

      attr_reader(*NAMES)

      private

      def assign(options)
        unknown = options.keys - NAMES
        raise ConfigurationError, "unknown option #{unknown.first.inspect} (known: #{NAMES.join(', ')})" if unknown.any?

        assign_format(options)
        assign_lists(options)
        assign_offensive(options.fetch(:offensive))
        assign_generator(options.fetch(:generator))
        @reserve_routes = boolean(:reserve_routes, options.fetch(:reserve_routes))
        @app_name = valid_app_name(options.fetch(:app_name))
        @unique_index = valid_unique_index(options.fetch(:unique_index))
      end

      def assign_format(options)
        @length = valid_length(options.fetch(:length))
        @separators = valid_separators(options.fetch(:separators))
        @edge_separators = boolean(:edge_separators, options.fetch(:edge_separators))
        @case = one_of(:case, options.fetch(:case), CASES)
        @first_character = one_of(:first_character, options.fetch(:first_character), FIRST_CHARACTERS)
      end

      def assign_lists(options)
        @reserved = valid_words(:reserved, options.fetch(:reserved))
        @forbidden = valid_words(:forbidden, options.fetch(:forbidden))
        @allowed = valid_words(:allowed, options.fetch(:allowed))
        @reserved_if = valid_callable(:reserved_if, options.fetch(:reserved_if), "->(name) { … }")
        @on_adapter_failure = one_of(:on_adapter_failure, options.fetch(:on_adapter_failure), ADAPTER_FAILURE_MODES)
      end

      def assign_offensive(offensive)
        offensive = settings(:offensive, offensive, OFFENSIVE_NAMES)
        @offensive = OffensiveSettings.new(
          severity: one_of(:"offensive.severity", offensive[:severity], SEVERITIES),
          languages: valid_languages(offensive[:languages]),
          allowed: valid_words(:"offensive.allowed", offensive[:allowed]),
          adapters: valid_adapters(offensive[:adapters])
        )
      end

      def assign_generator(generator)
        generator = settings(:generator, generator, GENERATOR_NAMES)
        callable = generator[:callable]
        unless callable.nil? || callable.respond_to?(:call)
          invalid!(:generator, callable, "a callable such as ->(attempt) { … }")
        end

        @generator = GeneratorSettings.new(
          adjectives: valid_words(:"generator.adjectives", generator[:adjectives]),
          nouns: valid_words(:"generator.nouns", generator[:nouns]),
          callable: callable
        )
      end

      def valid_length(value)
        valid = value.is_a?(Range) && value.begin.is_a?(Integer) && value.end.is_a?(Integer) &&
                value.min.to_i >= 1
        invalid!(:length, value, "a Range of whole numbers from 1 up, like 3..30") unless valid

        value.min..value.max
      end

      def valid_separators(value)
        unless value.is_a?(Array) && value.all? { |separator| SEPARATORS.include?(separator) }
          invalid!(:separators, value, "a list drawn from #{SEPARATORS.map(&:inspect).join(', ')}, like %w[_]")
        end

        value.uniq.freeze
      end

      def one_of(name, value, choices)
        invalid!(name, value, "one of #{choices.map(&:inspect).join(', ')}") unless choices.include?(value)

        value
      end

      def boolean(name, value)
        one_of(name, value, [true, false])
      end

      # A list of words, naming the one entry that is not a word rather than
      # printing a list that may hold a thousand of them.
      def valid_words(name, value)
        invalid!(name, value, "a list of words, like %w[recipe]") unless value.is_a?(Array)
        # An index, not the entry itself: the bad entry may be nil.
        bad = value.index { |word| !word.is_a?(String) || word.strip.empty? }
        raise ConfigurationError, "#{name} must be a list of words, like %w[recipe] (got #{value[bad].inspect} in it)" if bad

        value.dup.freeze
      end

      # Only languages whose words ship: a language without data would refuse
      # nothing, so a typo (`:sp`) or a language not tiered yet would switch
      # the word check off without a word of warning.
      def valid_languages(value)
        unless value.is_a?(Array) && value.all?(Symbol)
          invalid!(:"offensive.languages", value, "a list of locale symbols, like %i[en es]")
        end
        unknown = value - Data.available_locales
        if unknown.any?
          raise ConfigurationError, "offensive.languages has no word list for #{unknown.first.inspect} " \
                                    "(available: #{Data.available_locales.map(&:inspect).join(', ')})"
        end

        value.uniq.freeze
      end

      # :moderate (a no-op unless the moderate gem is loaded) or any callable
      # that takes the name.
      def valid_adapters(value)
        unless value.is_a?(Array) && value.all? { |adapter| adapter == :moderate || adapter.respond_to?(:call) }
          invalid!(:"offensive.adapters", value, "a list of :moderate or callables, like [:moderate]")
        end

        value.dup.freeze
      end

      # nil detects the name from the Rails application; false opts out; a
      # String names it explicitly (an app whose brand is not its module name).
      # nil, or anything that answers `call`.
      def valid_callable(name, value, example)
        invalid!(name, value, "nil or a callable such as #{example}") unless value.nil? || value.respond_to?(:call)

        value
      end

      def valid_app_name(value)
        valid = value.nil? || value == false || (value.is_a?(String) && !value.strip.empty?)
        invalid!(:app_name, value, "a String, false to opt out, or nil to detect it") unless valid

        value
      end

      def valid_unique_index(value)
        valid = value.nil? || ((value.is_a?(String) || value.is_a?(Symbol)) && !value.empty?)
        invalid!(:unique_index, value, "the name of an index, or nil") unless valid

        value
      end

      def settings(name, value, names)
        invalid!(name, value, "a Hash of #{names.join(', ')}") unless value.is_a?(Hash)
        unknown = value.keys - names
        raise ConfigurationError, "unknown option #{name}.#{unknown.first} (known: #{names.join(', ')})" if unknown.any?

        value
      end

      def invalid!(name, value, expectation)
        raise ConfigurationError, "#{name} must be #{expectation} (got #{value.inspect})"
      end
    end
  end
end
