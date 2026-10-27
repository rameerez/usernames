# frozen_string_literal: true

# `require "usernames/model"` on its own (Active Record without Rails) brings
# the rest of the gem with it.
require_relative "../usernames" unless defined?(Usernames::Configuration)

module Usernames
  # `has_username`, on every Active Record model: the engine extends
  # ActiveRecord::Base with this module when Active Record loads, and so does
  # requiring this file without Rails.
  #
  #   class User < ApplicationRecord
  #     has_username
  #   end
  #
  #   class Player < ApplicationRecord
  #     has_username :handle, length: 2..24, case: :preserve, separators: %w[_ . -]
  #   end
  module Model
    def self.extended(base)
      return if base.respond_to?(:_usernames)

      # { column => Usernames::Model::Column } for every has_username of a
      # model (and, inherited, of its subclasses). :nodoc:
      base.class_attribute :_usernames, instance_accessor: false, default: {}.freeze
    end

    # has_username(column = :username, required: false, generate: true, **rules)
    #
    # Installs, for that column (PRD §6.1):
    #
    # 1. `normalizes`, so " @Javi " is stored as "javi" and a blank as nil;
    # 2. the username rules, checked only when the value changes — a rule
    #    added later never stops an old account from saving its other
    #    attributes (D-11);
    # 3. with `required: true`, presence — on create, and on an update that
    #    changes it (a legacy blank still saves unrelated changes);
    # 4. uniqueness, compared the way the unique index compares (Comparison);
    # 5. a generated name on create when none was given (unless `required:`
    #    or `generate: false`);
    # 6. a race wrapper, so two sign-ups racing for one name end in a redraw
    #    (a generated name) or in "has already been taken" (a typed one) —
    #    never a RecordNotUnique 500.
    #
    # And the class helpers, named after the column: `username_available?`,
    # `suggest_usernames`, `generate_username`, `find_by_username`
    # (`handle_available?`, `suggest_handles`, … for `has_username :handle`).
    #
    # The case mode is read here, once: the unique index is built for one
    # mode, so the model keeps comparing in it even if the configuration
    # changes later. Every other rule is read from the configuration on each
    # check.
    def has_username(column = :username, required: false, generate: true, **rules)
      column = Column.new(self, column, required: required, generate: generate, rules: rules)
      if _usernames.key?(column.name)
        raise ConfigurationError, "has_username :#{column.name} is already declared on #{name || self}"
      end

      self._usernames = _usernames.merge(column.name => column).freeze
      column.install
    end

    # One has_username declaration, and everything that column needs: the
    # rules in force, the comparison expression, and the queries behind the
    # class helpers. :nodoc:
    class Column
      attr_reader :model, :name, :required, :generate, :options

      def initialize(model, name, required:, generate:, rules:)
        @model = model
        @name = name.to_sym
        @required = boolean(:required, required)
        # PRD §6.1: `required: true` turns generation off — the person chooses.
        @generate = boolean(:generate, generate) && !@required
        # Resolving them now raises ConfigurationError for a bad option when
        # the model is defined, and pins the case mode (see has_username).
        @options = rules.merge(case: Usernames.configuration.rules_for(**rules).case).freeze
      end

      def mode
        options.fetch(:case)
      end

      # The Usernames::Rules in force: the configuration as it is now, with
      # this column's options over it (cached by the configuration).
      def rules
        Usernames.configuration.rules_for(**options)
      end

      def install
        install_normalization_and_rules
        install_uniqueness
        model.before_validation(:"assign_#{name}", on: :create) if generate
        model.include(InstanceMethods.for(name))
        model.extend(ClassMethods.for(self))
      end

      # The comparison expression, for a bound predicate.
      def sql(on = model)
        Comparison.sql(on, name)
      end

      # Those of `names` nobody has, in order — ONE query for all of them.
      def free(names, rules, on)
        return [] if names.empty?

        keys = names.map { |candidate| rules.comparison_key(candidate) }
        expression = sql(on)
        taken = on.base_class.unscoped.where("#{expression} IN (?)", keys.uniq)
          .pluck(Arel.sql(expression)).to_set { |stored| rules.comparison_key(stored.to_s) }
        names.reject { |candidate| taken.include?(rules.comparison_key(candidate)) }
      end

      # Whether someone else already has the canonical name `canonical`.
      # `except` is the record itself, so a case-only change (`Javi` → `JAVI`
      # in preserve mode) does not collide with its own row.
      def taken?(canonical, on, except: nil)
        scope = on.base_class.unscoped.where("#{sql(on)} = ?", rules.comparison_key(canonical))
        scope = scope.where.not(on.primary_key => except.id_in_database) if except&.persisted?
        scope.exists?
      end

      private

      def install_normalization_and_rules
        column = name
        changed = :"will_save_change_to_#{column}?"
        model.normalizes column, with: Usernames.normalizer(**options)
        model.validates column, username: options, if: changed
        return unless required

        # On create, and when an update touches it: a pre-existing blank
        # saves unrelated changes; clearing a name is :blank.
        model.validates column, presence: true, if: -> { new_record? || will_save_change_to_attribute?(column) }
      end

      # Lowercase mode stores the canonical value, so Rails' own exact
      # comparison on a byte-compared column is the contract. Preserve mode
      # needs the comparison expression, which Rails' `case_sensitive: false`
      # (a collation-dependent LOWER()) is not.
      def install_uniqueness
        changed = :"will_save_change_to_#{name}?"
        if mode == :preserve
          model.validate :"validate_#{name}_uniqueness", if: changed
        else
          model.validates name, uniqueness: { case_sensitive: true }, allow_nil: true, if: changed
        end
      end

      def boolean(option, value)
        return value if [true, false].include?(value)

        raise ConfigurationError, "has_username #{option}: must be true or false (got #{value.inspect})"
      end
    end

    # The class helpers for one column, as a module the model extends.
    module ClassMethods
      def self.for(column)
        Module.new.tap do |helpers|
          %i[available suggest generate find_by options].each { |helper| send(helper, helpers, column) }
        end
      end

      # User.username_available?("javi") — false when taken, reserved, not allowed or invalid.
      def self.available(helpers, column)
        helpers.define_method(:"#{column.name}_available?") do |value|
          rules = column.rules
          canonical = rules.normalize(value)
          !canonical.empty? && rules.failure_for(canonical).nil? && !column.taken?(canonical, self)
        end
      end

      # User.suggest_usernames("Javi R", count: 5) — up to `count` free
      # names, in one query; possibly fewer, even [].
      def self.suggest(helpers, column)
        helpers.define_method(:"suggest_#{column.name.to_s.pluralize}") do |seed = nil, count: 5|
          rules = column.rules
          column.free(Candidates.for(seed, count: count, rules: rules), rules, self).first(count)
        end
      end

      # User.generate_username / User.generate_username(from: "José García") —
      # one batch of candidates, one query, the first free one.
      def self.generate(helpers, column)
        helpers.define_method(:"generate_#{column.name}") do |from: nil|
          rules = column.rules
          free = column.free(Generator.candidates(from: from, rules: rules), rules, self).first
          free || raise(NoFreeNameError, "every generated #{column.name} in this batch is taken or not allowed; " \
                                         "check length, separators and the generator's word lists")
        end
      end

      # User.find_by_username("@Javi") — normalised, then compared as the index compares.
      def self.find_by(helpers, column)
        helpers.define_method(:"find_by_#{column.name}") do |value|
          rules = column.rules
          canonical = rules.normalize(value)
          find_by("#{column.sql(self)} = ?", rules.comparison_key(canonical)) unless canonical.empty?
        end
      end

      # The rule options of this column, for Usernames.check and
      # Usernames.rules_for_browser (the generated availability check uses them).
      # NOTE(p3): not in PRD §6.1's list; the availability generator needs
      # the model's own rules to tell "invalid" from "taken".
      def self.options(helpers, column)
        helpers.define_method(:"#{column.name}_options") { column.options }
      end
    end

    # The instance side for one column: `username_generated?`, generation on
    # create, preserve-mode uniqueness and the race wrapper (PRD §11.3).
    #
    # Written with module_eval rather than define_method because the race
    # wrapper calls `super` from inside a block, which only a `def` allows.
    module InstanceMethods
      def self.for(column)
        Module.new.tap { |methods| methods.module_eval(source(column), __FILE__, SOURCE_LINE) }
      end

      # Where the heredoc below starts, so a backtrace points at the real line.
      SOURCE_LINE = __LINE__ + 4

      def self.source(column)
        <<~RUBY
          # Whether the gem assigned this record's current #{column} (on create, or in a redraw).
          def #{column}_generated?
            !@#{column}_generated.nil? && @#{column}_generated == #{column}
          end

          private

          def assign_#{column}
            self.#{column} = @#{column}_generated = self.class.generate_#{column} if #{column}.blank?
          end

          def validate_#{column}_uniqueness
            return if #{column}.nil?

            column = self.class._usernames.fetch(:#{column})
            errors.add(:#{column}, :taken, value: #{column}) if column.taken?(#{column}, column.model, except: self)
          end

          def _create_record(...)
            with_#{column}_race_handling(redraw: #{column}_generated?) { super }
          end

          def _update_record(...)
            return super unless will_save_change_to_#{column}?

            with_#{column}_race_handling(redraw: false) { super }
          end

          # The insert or update runs inside a savepoint, and the unique
          # violation is rescued OUTSIDE it: by then the savepoint has rolled
          # back, so the surrounding transaction is usable again and a
          # redraw (or the query that reads the indexes) can run in it.
          def with_#{column}_race_handling(redraw:)
            attempts = 0
            loop do
              begin
                return self.class.transaction(requires_new: true) { yield }
              rescue ActiveRecord::RecordNotUnique => error
                column = self.class._usernames.fetch(:#{column})
                raise unless Usernames::UniqueViolation.of?(error, table: self.class.table_name, column: :#{column},
                                                                   index: column.rules.unique_index,
                                                                   connection: self.class.lease_connection)

                if redraw && (attempts += 1) <= 3
                  self.#{column} = @#{column}_generated = self.class.generate_#{column}   # generated names only
                else
                  errors.add(:#{column}, :taken)                                          # typed names, or redraws exhausted
                  raise ActiveRecord::RecordInvalid, self                                 # save → false, save! → RecordInvalid
                end
              end
            end
          end
        RUBY
      end
    end
  end
end

# Without Rails there is no engine to do it (see Usernames::Engine).
ActiveSupport.on_load(:active_record) { extend Usernames::Model }
