# frozen_string_literal: true

require "active_support/core_ext/integer/time"

module Usernames
  # `Usernames.configure { |config| … }`. The generated initializer shows ten
  # of these options; the README documents the rest.
  #
  # Word lists START FROM the bundled data, so `+=` adds to it and `=`
  # replaces it:
  #
  #   config.reserved += %w[recipe recipes]   # the bundled words, and these
  #   config.reserved  = %w[recipe recipes]   # only these
  #
  # Lists are handed out frozen. The rules compiled from them are cached, and
  # a list changed behind the cache's back (`config.reserved << "x"`) would
  # be ignored without a word — so that raises FrozenError instead, and the
  # two spellings above are the ones that work.
  #
  # Nothing is checked as you assign: validate! (run at the end of configure,
  # and by the Rails engine after boot) checks every value at once and raises
  # Usernames::ConfigurationError naming the bad one.
  class Configuration
    # Accessors whose writers invalidate the compiled rules.
    module Settings
      def option(*names)
        names.each do |name|
          attr_reader name

          define_method(:"#{name}=") do |value|
            changed!
            instance_variable_set(:"@#{name}", value.is_a?(Array) ? value.dup.freeze : value)
          end
        end
      end
    end

    extend Settings

    # config.offensive.severity / .languages / .allowed / .adapters
    class Offensive
      extend Settings

      option :severity, :languages, :allowed, :adapters

      def initialize(configuration)
        @configuration = configuration
        @severity = :strong
        @languages = %i[en es].freeze
        # Your own exemptions, so — unlike reserved and forbidden — this list
        # starts empty: the bundled allowlists are per language and apply only
        # inside their own language, so they are not merged in here.
        @allowed = [].freeze
        # A no-op unless the moderate gem is loaded.
        @adapters = [:moderate].freeze
      end

      def to_h
        { severity: severity, languages: languages, allowed: allowed, adapters: adapters }
      end

      private

      def changed!
        @configuration.changed!
      end
    end

    # config.generator.adjectives / .nouns, or config.generator = ->(attempt) { … }
    class Generator
      extend Settings

      option :adjectives, :nouns, :callable

      def initialize(configuration)
        @configuration = configuration
        @adjectives = Data.adjectives
        @nouns = Data.nouns
        @callable = nil
      end

      def to_h
        { adjectives: adjectives, nouns: nouns, callable: callable }
      end

      private

      def changed!
        @configuration.changed!
      end
    end

    # config.availability: the built-in "is this name free?" endpoint. None
    # of it is a rule, so nothing here touches the compiled rules.
    class Availability
      # The route drawn for the endpoint; nil or false draws none.
      attr_accessor :path

      # Which username columns the endpoint answers for, by an alias the
      # browser sends: { "user" => "User#handle" }. Nothing else is ever
      # looked up, so a model with has_username is not published by
      # declaring it. The install generator writes yours.
      attr_accessor :targets

      # The class the endpoint inherits from, by name. nil: your
      # ApplicationController when there is one (its locale and
      # authentication callbacks apply), else ActionController::Base.
      # "ActionController::API" works too.
      attr_accessor :parent_controller

      # Rails' rate_limit, per client IP: { to: 30, within: 1.minute }.
      attr_accessor :rate_limit

      # Where the rate limit counts. nil: Rails.cache. Read once, when the
      # endpoint's class loads, so a change needs a restart.
      attr_accessor :rate_limit_store

      ALIAS = /\A[a-z0-9][a-z0-9_-]*\z/
      TARGET = /\A[A-Z]\w*(?:::[A-Z]\w*)*#[a-z_]\w*\z/

      def initialize
        @path = "/usernames/availability"
        @targets = {}.freeze
        @parent_controller = nil
        @rate_limit = { to: 30, within: 1.minute }.freeze
        @rate_limit_store = nil
      end

      # The endpoint's superclass (see parent_controller). :nodoc:
      def parent_class
        name = parent_controller
        name ||= Object.const_defined?(:ApplicationController) ? "ApplicationController" : "ActionController::Base"
        Object.const_get(name)
      end

      def validate!
        valid_path!
        valid_targets!
        unless parent_controller.nil? || (parent_controller.is_a?(String) && !parent_controller.empty?)
          invalid!(:parent_controller, parent_controller, "a class name as a String, like \"ApplicationController\"")
        end
        valid_rate_limit!
      end

      private

      def valid_path!
        return if [nil, false].include?(path) || (path.is_a?(String) && path.match?(%r{\A/[^/?#\s]}))

        invalid!(:path, path, "a path like \"/usernames/availability\", or nil to draw no route")
      end

      def valid_targets!
        valid = targets.is_a?(Hash) && targets.all? do |name, target|
          name.is_a?(String) && name.match?(ALIAS) && target.is_a?(String) && target.match?(TARGET)
        end
        return if valid

        invalid!(:targets, targets, "a Hash of aliases to \"Model#column\" Strings, like { \"user\" => \"User#handle\" }")
      end

      def valid_rate_limit!
        limit = rate_limit
        valid = limit.is_a?(Hash) && limit.keys.sort == %i[to within] && limit[:to].is_a?(Integer) &&
                limit[:to].positive? && limit[:within].is_a?(Numeric) && limit[:within].positive?
        return if valid

        invalid!(:rate_limit, limit, "{ to: 30, within: 1.minute }: a whole number of requests per period")
      end

      def invalid!(option, value, expected)
        raise ConfigurationError, "config.availability.#{option} must be #{expected} (got #{value.inspect})"
      end
    end

    # Per-call word lists ADD to the configured ones: a model that passes
    # `reserved: %w[recipe]` keeps every bundled reservation. Every other
    # per-call option replaces the configured value. Adding is the choice
    # that can never silently un-reserve a name: a per-model list fails closed.
    LISTS = %i[reserved forbidden allowed].freeze

    # Distinct per-call option sets kept compiled. They come from model and
    # validator declarations, so a handful in practice; the limit only stops
    # a caller passing fresh options on every request from growing it forever.
    CACHE_LIMIT = 64

    option :length, :separators, :edge_separators, :case, :first_character, :reserve_routes, :app_name,
           :reserved, :forbidden, :allowed, :on_adapter_failure, :unique_index

    attr_reader :offensive, :generator, :availability

    def initialize
      @length = 3..30
      @separators = %w[_].freeze
      @edge_separators = false
      @case = :lowercase
      @first_character = :alphanumeric
      @reserve_routes = true
      @app_name = nil # detected from the Rails application; false opts out
      @reserved = Data.reserved
      @forbidden = Data.impersonation
      @allowed = [].freeze
      @on_adapter_failure = :allow
      @unique_index = nil
      @offensive = Offensive.new(self)
      @generator = Generator.new(self)
      @availability = Availability.new
    end

    # `config.generator = ->(attempt) { … }` replaces the default shape;
    # the word lists stay at config.generator.adjectives / .nouns.
    def generator=(callable)
      generator.callable = callable
    end

    # The compiled, frozen Usernames::Rules for these per-call options merged
    # over this configuration, raising ConfigurationError for a bad value.
    def rules_for(**overrides)
      cache = (@rules_cache ||= {})
      cache.clear if cache.size >= CACHE_LIMIT
      cache[overrides] ||= begin
        options = merge(overrides)
        Rules.new(**options)
      end
    end

    def validate!
      rules_for
      availability.validate!
      self
    end

    def to_h
      {
        length: length, separators: separators, edge_separators: edge_separators, case: @case,
        first_character: first_character, reserve_routes: reserve_routes, app_name: app_name,
        reserved: reserved, forbidden: forbidden, allowed: allowed, offensive: offensive.to_h,
        on_adapter_failure: on_adapter_failure, generator: generator.to_h, unique_index: unique_index
      }
    end

    # Called by every writer, including those of config.offensive and
    # config.generator. :nodoc:
    def changed!
      @rules_cache = nil
    end

    private

    def merge(overrides)
      options = to_h
      overrides.each do |name, value|
        options[name] =
          case name
          when *LISTS then added(options[name], value)
          when :offensive then merged_offensive(options[:offensive], value)
          when :generator then merged_generator(options[:generator], value)
          else value
          end
      end
      options
    end

    # Anything that is not a list is passed on as given, for Rules to refuse by name.
    def added(list, value)
      value.is_a?(Array) ? list + value : value
    end

    def merged_offensive(settings, value)
      return value unless value.is_a?(Hash)

      settings.merge(value) do |name, configured, given|
        name == :allowed ? added(configured, given) : given
      end
    end

    def merged_generator(settings, value)
      return settings.merge(callable: value) if value.nil? || value.respond_to?(:call)
      return value unless value.is_a?(Hash)

      settings.merge(value)
    end
  end
end
