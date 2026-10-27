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

    # has_username(column = :username, required: false, generate: nil, **rules)
    #
    # Installs, for that column:
    #
    # 1. `normalizes`, so " @Javi " is stored as "javi" and a blank as nil;
    # 2. the username rules, checked only when the value changes — a rule
    #    added later never stops an old account from saving its other
    #    attributes;
    # 3. with `required:`, presence — on create, and on an update that
    #    changes it (a legacy blank still saves unrelated changes);
    # 4. uniqueness, compared the way the unique index compares (Comparison);
    # 5. a generated name on create when none was given — by default, unless
    #    a name is required for that record;
    # 6. a race wrapper, so two sign-ups racing for one name end in a redraw
    #    (a generated name) or in "has already been taken" (a typed one) —
    #    never a RecordNotUnique 500.
    #
    # `required:` and `generate:` take true, false, a method name or a proc,
    # evaluated on the record the way Rails' `if:` is: a sign-up flow that
    # asks for a name (`required: :handle_required`) gets presence, and every
    # other record a generated name.
    #
    # And the class helpers, named after the column: `username_available?`,
    # `suggest_usernames`, `generate_username`, `find_by_username` (and `!`),
    # `username_options`, `check_username`, `username_rules_for_browser`
    # (`handle_available?`, `suggest_handles`, … for `has_username :handle`).
    #
    # The case mode is read here, once: the unique index is built for one
    # mode, so the model keeps comparing in it even if the configuration
    # changes later. Every other rule is read from the configuration on each
    # check.
    def has_username(column = :username, required: false, generate: nil, **rules)
      column = Column.new(self, column, required: required, generate: generate, rules: rules)
      if _usernames.key?(column.name)
        raise ConfigurationError, "has_username :#{column.name} is already declared on #{name || self}"
      end

      self._usernames = _usernames.merge(column.name => column).freeze
      column.install
    end

    # true, false, or a condition evaluated on `record` as Rails evaluates
    # `if:` — a Symbol is a method sent to it, a proc without arguments is
    # run on it, a proc with one is given it. :nodoc:
    def self.applies?(condition, record)
      result =
        case condition
        when true, false then condition
        when Symbol then record.send(condition)
        else condition.arity.zero? ? record.instance_exec(&condition) : condition.call(record)
        end
      result ? true : false
    end

    # One has_username declaration, and everything that column needs: the
    # rules in force, the comparison expression, and the queries behind the
    # class helpers. :nodoc:
    class Column
      attr_reader :model, :name, :required, :generate, :options

      def initialize(model, name, required:, generate:, rules:)
        @model = model
        @name = name.to_sym
        @required = condition(:required, required)
        # By default a name is generated exactly where none is required: where
        # one is, the person chooses.
        @generate = generate.nil? ? nil : condition(:generate, generate)
        # Resolving them now raises ConfigurationError for a bad option when
        # the model is defined, and pins the case mode (see has_username).
        @options = rules.merge(case: Usernames.configuration.rules_for(**rules).case).freeze
      end

      # Whether `record` must have a name.
      def required?(record)
        Model.applies?(required, record)
      end

      # Whether `record` gets a generated name on create when it has none.
      def generate?(record)
        generate.nil? ? !required?(record) : Model.applies?(generate, record)
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
        install_generation
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

      # Whether a RecordNotUnique raised while saving a record of `on` came
      # from this column's unique index, read on the connection the save is
      # using. with_connection, not lease_connection: inside a scoped
      # checkout (a thread or job wrapped in `with_connection`),
      # lease_connection would turn it into a permanent lease, and the
      # connection would stay checked out after the block, held by a thread
      # that may already be gone.
      def violated_by?(error, on)
        on.with_connection do |connection|
          UniqueViolation.of?(error, table: on.table_name, column: name, rules: rules, connection: connection)
        end
      end

      private

      def install_normalization_and_rules
        column = name
        definition = self
        changed = :"will_save_change_to_#{column}?"
        model.normalizes column, with: Usernames.normalizer(**options)
        model.validates column, username: options, if: changed
        return if required == false

        # On create, and when an update touches it: a pre-existing blank
        # saves unrelated changes; clearing a name is :blank.
        model.validates column, presence: true, if: lambda {
          (new_record? || will_save_change_to_attribute?(column)) && definition.required?(self)
        }
      end

      # Left out altogether when no record can ever get a generated name.
      def install_generation
        return if generate == false || (generate.nil? && required == true)

        definition = self
        model.before_validation(:"assign_#{name}", on: :create, if: -> { definition.generate?(self) })
      end

      # Lowercase mode stores the canonical value, so Rails' own exact
      # comparison on a byte-compared column is the contract. Preserve mode
      # needs the comparison expression, which Rails' `case_sensitive: false`
      # (a collation-dependent LOWER()) is not.
      #
      # Skipped when the name already failed a rule: one error per name, the
      # first that applies — a new `admin` is reserved, whoever else is
      # called that.
      def install_uniqueness
        column = name
        checks = { if: :"will_save_change_to_#{name}?", unless: -> { errors.include?(column) } }
        if mode == :preserve
          model.validate :"validate_#{name}_uniqueness", **checks
        else
          model.validates name, uniqueness: { case_sensitive: true }, allow_nil: true, **checks
        end
      end

      def condition(option, value)
        return value if [true, false].include?(value) || value.is_a?(Symbol) || value.is_a?(Proc)

        raise ConfigurationError, "has_username #{option}: must be true, false, a method name or a proc " \
                                  "(got #{value.inspect})"
      end
    end

    # The class helpers for one column, as a module the model extends.
    module ClassMethods
      def self.for(column)
        Module.new.tap do |helpers|
          %i[available suggest generate find_by options check browser].each { |helper| send(helper, helpers, column) }
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

      # User.find_by_username("@Javi") — normalised, then compared as the index
      # compares; nil when nobody has it. User.find_by_username!("@Javi") raises
      # ActiveRecord::RecordNotFound instead, as find_by! does, so a profile
      # route answers 404.
      def self.find_by(helpers, column)
        finder = :"find_by_#{column.name}"
        helpers.define_method(finder) do |value|
          rules = column.rules
          canonical = rules.normalize(value)
          find_by("#{column.sql(self)} = ?", rules.comparison_key(canonical)) unless canonical.empty?
        end
        helpers.define_method(:"#{finder}!") do |value|
          public_send(finder, value) ||
            raise(ActiveRecord::RecordNotFound.new("Couldn't find #{name} with #{column.name} #{value.inspect}", name))
        end
      end

      # The rule options of this column, for Usernames.check,
      # Usernames.comparison_key and Usernames.rules_for_browser.
      # The availability check needs the model's own rules to tell
      # "invalid" from "taken".
      def self.options(helpers, column)
        helpers.define_method(:"#{column.name}_options") { column.options }
      end

      # User.check_username("Ad_min") — Usernames.check with this column's
      # rules, its message worded as this model's own error would be (a
      # per-model translation wins). Eligibility only, like Usernames.check:
      # no query, so `ok?` says nothing about whether the name is free.
      def self.check(helpers, column)
        helpers.define_method(:"check_#{column.name}") do |value|
          rules = column.rules
          canonical = rules.normalize(value)
          Result.for(canonical, rules.failure_for(canonical), record: new, attribute: column.name)
        end
      end

      # User.username_rules_for_browser — Usernames.rules_for_browser with
      # this column's rules and this model's words, for the hints a form
      # shows while someone types.
      def self.browser(helpers, column)
        helpers.define_method(:"#{column.name}_rules_for_browser") { column.rules.for_browser(new, column.name) }
      end
    end

    # The instance side for one column: `username_generated?`, generation on
    # create, preserve-mode uniqueness and the race wrapper.
    module InstanceMethods
      def self.for(column)
        Module.new.tap do |methods|
          define_generation(methods, column)
          define_uniqueness(methods, column)
          methods.module_eval(source(column), __FILE__, SOURCE_LINE)
        end
      end

      # `username_generated?`, and drawing a name on create or in a redraw.
      # A batch with nothing free in it is a validation error, not an
      # exception: `save` returns false, `save!` raises RecordInvalid.
      def self.define_generation(methods, column)
        generated = :"@#{column}_generated"
        # Whether the gem assigned this record's current name (on create, or in a redraw).
        methods.define_method(:"#{column}_generated?") do
          drawn = instance_variable_get(generated)
          !drawn.nil? && drawn == public_send(column)
        end
        methods.define_method(:"draw_#{column}") do
          public_send(:"#{column}=", instance_variable_set(generated, self.class.public_send(:"generate_#{column}")))
        rescue NoFreeNameError
          errors.add(column, :username_unavailable)
        end
        methods.define_method(:"assign_#{column}") { send(:"draw_#{column}") if public_send(column).blank? }
        methods.send(:private, :"draw_#{column}", :"assign_#{column}")
      end

      # Preserve mode's uniqueness check, against the record's own class: a
      # model that inherits has_username from an abstract parent has the table.
      def self.define_uniqueness(methods, column)
        methods.define_method(:"validate_#{column}_uniqueness") do
          value = public_send(column)
          taken = !value.nil? && self.class._usernames.fetch(column).taken?(value, self.class, except: self)
          errors.add(column, :taken, value: value) if taken
        end
        methods.send(:private, :"validate_#{column}_uniqueness")
      end

      # Where the heredoc below starts, so a backtrace points at the real line.
      SOURCE_LINE = __LINE__ + 6

      # What has to be a `def`: these call `super`, and the race wrapper's
      # block does, which define_method cannot.
      def self.source(column)
        <<~RUBY
          private

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
                raise unless self.class._usernames.fetch(:#{column}).violated_by?(error, self.class)

                if redraw && (attempts += 1) <= 3
                  draw_#{column}                              # generated names only
                else
                  errors.add(:#{column}, :taken)              # typed names, or redraws exhausted
                end
                raise ActiveRecord::RecordInvalid, self if errors.include?(:#{column}) # save → false, save! → RecordInvalid
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
