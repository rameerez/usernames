# frozen_string_literal: true

require_relative "audit/values"
require_relative "audit/output"

module Usernames
  # `rails usernames:audit[User,username]` (PRD §11.5): what stands between an
  # existing column and the gem's guarantees. Read-only — it never writes a
  # row, an index or a setting.
  #
  # Rails' `normalizes` does not touch rows already in the database, so a
  # stored `JAVI` next to a new `javi` would be two identities, and a unique
  # index cannot be added over values that collide once normalised. The
  # audit lists exactly that, plus whether the column's type, collation and
  # indexes give the comparison contract (Usernames::Comparison), and which
  # stored names today's rules would refuse — those keep working (only a
  # change is validated, D-11); they are listed so nobody is surprised.
  #
  # Fixing what it finds is the app's own migration, under a username-write
  # freeze (README, "Adopting an existing column"): the gem deliberately
  # renames nobody.
  class Audit
    include Output

    # Rows shown per finding; the counts are always complete.
    EXAMPLES = 20
    BATCH = 10_000

    # The types the comparison contract covers (PRD §11.1); citext is excluded (D-17).
    POSTGRESQL_TYPES = /\A(text|character varying(\(\d+\))?)\z/
    MODES = %i[lowercase preserve].freeze

    attr_reader :model, :column, :rules, :mode

    # `mode` audits as that case mode: the README's adoption workflow runs the
    # audit BEFORE has_username is declared, when the model cannot say which
    # mode its index will be built for.
    def initialize(model, column = :username, mode: nil)
      @model = model.is_a?(String) ? model.constantize : model
      @column = column.to_sym
      @definition = @model._usernames[@column] if @model.respond_to?(:_usernames)
      @mode_given = !mode.to_s.empty?
      @mode = @mode_given ? mode.to_sym : Comparison.mode_for(@model, @column)
      raise ArgumentError, "mode must be lowercase or preserve (got #{mode.inspect})" unless MODES.include?(@mode)

      @rules = @definition ? @definition.rules : Usernames.configuration.rules_for(case: @mode)
      @problems = 0
    end

    # Writes the report to `io` and returns the number of problems found
    # (values failing today's rules are a note, not a problem).
    def report(io = $stdout)
      @io = io
      line "usernames:audit #{model.name}##{column} (#{model.table_name}.#{column}, #{mode} mode, " \
           "#{connection.adapter_name}) — read-only"
      undeclared_note
      return finish unless column_section

      index_section
      values_section
      finish
    end

    private

    def connection
      model.lease_connection
    end

    def adapter
      Comparison.adapter(connection)
    end

    # Without the declaration the audit cannot know the column's own rules
    # (length, separators…) or, unless told, its case mode.
    def undeclared_note
      return if @definition

      other = (MODES - [mode]).first
      mode_hint = @mode_given ? "" : " (the configured one; for #{other}: usernames:audit[#{model.name},#{column},#{other}])"
      line "  · #{model.name} doesn't declare has_username :#{column} yet: checked against the configured rules, " \
           "in #{mode} mode#{mode_hint}"
    end

    # --- the column (PRD §11.1 criteria per adapter) ------------------------------------------------

    def column_section
      section "Column"
      definition = model.columns_hash[column.to_s]
      if definition
        type_and_collation(definition)
      else
        problem("there is no column #{model.table_name}.#{column} (rails generate usernames:install adds it)")
      end
      definition
    end

    def type_and_collation(definition)
      collation = definition.collation
      case adapter
      when :postgresql then postgresql_column(definition.sql_type, collation || database_collation)
      when :mysql then expect_collation(definition.sql_type, collation, "utf8mb4_bin")
      else sqlite_column(definition.sql_type, collation)
      end
    end

    def postgresql_column(type, collation)
      if type == "citext"
        return problem("citext is incompatible: its case-insensitivity follows the database locale (D-17); " \
                       "use a string column with collation \"C\"")
      end

      problem("#{type} is not text or character varying") unless POSTGRESQL_TYPES.match?(type)
      # Preserve mode compares lower(column COLLATE "C"): the explicit
      # collation wins, so the column's own one only decides ORDER BY.
      return ok(%(#{type}, collation #{collation.inspect} (compared through COLLATE "C"))) if mode == :preserve

      if collation == "C"
        ok %(#{type}, collation "C")
      else
        problem(%(#{type}, collation #{collation.inspect}: equality and lower() follow it; set collation: "C"))
      end
      problem(%(collation #{collation.inspect} is nondeterministic: it can ignore case or punctuation)) unless
        deterministic?(collation)
    end

    def expect_collation(type, collation, expected)
      return ok("#{type}, collation #{expected}") if collation == expected

      problem("#{type}, collation #{collation.inspect}: set collation: #{expected.inspect}, a byte-wise comparison")
    end

    # SQLite's default BINARY is the contract; NOCASE (or any custom one) is not.
    def sqlite_column(type, collation)
      return ok("#{type}, default BINARY collation") if collation.nil? || collation.casecmp?("binary")

      problem("#{type}, COLLATE #{collation}: the contract is SQLite's default BINARY")
    end

    def database_collation
      connection.select_value("SELECT datcollate FROM pg_database WHERE datname = current_database()")
    end

    def deterministic?(collation)
      value = connection.select_value(
        "SELECT collisdeterministic FROM pg_collation WHERE collname = #{connection.quote(collation)}"
      )
      value.nil? || ActiveModel::Type::Boolean.new.cast(value)
    rescue ActiveRecord::StatementInvalid
      true # before PostgreSQL 12 every collation is deterministic, and the column does not exist
    end

    # --- indexes --------------------------------------------------------------------------------------

    # Every index that involves the column, each with why it does not
    # enforce the comparison contract (Comparison::IndexContract) — a
    # partial, composite or NOCASE unique index is not uniqueness.
    def index_section
      section "Index"
      matching = listed_indexes.find { |_index, reason| reason.nil? }&.first
      return ok("#{matching.name} matches the #{mode} mode") if matching

      problem("no unique index matches the #{mode} mode, so the database does not enforce uniqueness yet: " \
              "#{add_index_line}")
    end

    def add_index_line
      expected = contract.definition
      "add_index #{Comparison.ruby_name(model.table_name)}, #{expected[:column].inspect}, unique: true, " \
        "name: #{expected[:name].inspect}"
    end

    def contract
      @contract ||= Comparison::IndexContract.new(connection, table: model.table_name, column: column, mode: mode)
    end

    # [[index, reason], …] for every index that involves the column, each
    # printed with why it falls short (reason nil: it enforces the contract).
    def listed_indexes
      verdicts = connection.indexes(model.table_name).select { |index| contract.mentions?(index) }
        .map { |index| [index, contract.violation(index)] }
      verdicts.each { |index, reason| line "  · #{describe(index)}#{" — #{reason}" if reason}" }
    end

    def describe(index)
      "#{index.name} (#{index.unique ? 'unique' : 'not unique'} on #{Array(index.columns).join(', ')})"
    end
    # --- stored values ----------------------------------------------------------------------------------

    def values_section
      values = Values.new(rules)
      each_value { |id, value| values << [id, value] }
      section "Stored values (#{values.total} with a #{column})"
      noncanonical(values.noncanonical)
      collisions(values.collisions)
      notes(values.failing)
    end

    def noncanonical(rows)
      list(rows, "every stored #{column} is already in its normalised form",
           "%d differ from their normalised form (rewrite them in your own migration)") do |id, value, canonical|
        "##{id} #{value.inspect} → #{canonical.empty? ? 'nil' : canonical.inspect}"
      end
    end

    def collisions(groups)
      list(groups, "no two stored names collide once normalised",
           "groups that collide once normalised: %d (the unique index cannot be added over them)") do |key, rows|
        "#{key.inspect}: #{rows.map { |id, value| "##{id} #{value.inspect}" }.join(', ')}"
      end
    end

    def each_value(&)
      model.unscoped.where.not(column => nil).in_batches(of: BATCH) do |batch|
        batch.pluck(model.primary_key, column).each(&)
      end
    end

    def notes(failing)
      return ok("every stored #{column} passes today's rules") if failing.empty?

      line "  · #{failing.size} fail today's rules — they keep working; only a change is validated:"
      failing.first(EXAMPLES).each { |id, value, reason| line "      ##{id} #{value.inspect}: #{reason}" }
      more(failing)
    end
  end
end
