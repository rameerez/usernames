# frozen_string_literal: true

module Usernames
  # Whether an ActiveRecord::RecordNotUnique came from the username's own
  # unique index — the one that decides who has a name — or from another one.
  #
  # A duplicate email raises exactly the same exception class as a duplicate
  # username, and so does an app's own unique index that merely mentions the
  # column (`substr(username, 1, 3)`, `(tenant_id, username)`). Redrawing a
  # generated name over one of those would loop for nothing, and reporting it
  # as "username has already been taken" would be a lie that hides a real
  # error — so the race wrapper asks this first, and anything that is not the
  # username's identity index propagates untouched.
  #
  # Each adapter names the culprit differently:
  #
  #   PostgreSQL  the constraint (and its table and schema), from the server's error diagnostics
  #   MySQL       Duplicate entry 'javi' for key 'users.index_users_on_username'
  #   SQLite      UNIQUE constraint failed: users.username
  #               UNIQUE constraint failed: index 'index_users_on_lower_username'
  #
  # The identity index is the one the gem names itself, the app's configured
  # `unique_index`, or any index that passes the comparison contract for the
  # column (Comparison::IndexContract). SQLite's column form names no index,
  # so there the column must be the only one named, and the table must have
  # an identity index on exactly it.
  module UniqueViolation
    POSTGRESQL_CONSTRAINT = /unique constraint "(?<name>[^"]+)"/
    MYSQL_KEY = /for key '(?:(?<table>[^'.]+)\.)?(?<name>[^']+)'/
    SQLITE_COLUMNS = /UNIQUE constraint failed: (?<columns>[^:']+?)\s*\z/
    SQLITE_INDEX = /UNIQUE constraint failed: index '(?<name>[^']+)'/

    # What a violation is matched against: the table as the model names it
    # (possibly schema-qualified), its bare name, the column, the configured
    # index, the case mode and the connection to read indexes back with. :nodoc:
    Target = ::Data.define(:table, :bare_table, :column, :index, :mode, :connection)

    class << self
      # UniqueViolation.of?(error, table: "users", column: :username, rules: rules)
      #
      # `rules` are the column's Usernames::Rules: its case mode, and
      # config.unique_index (an index the generator did not create).
      # `connection` is the model's own, which reads its indexes back (an app
      # may have several databases); without one, Active Record's default
      # connection is used.
      def of?(error, table:, column:, rules: Usernames.configuration.rules_for, connection: nil)
        target = Target.new(table: table.to_s, bare_table: table.to_s.split(".").last, column: column.to_s,
                            index: rules.unique_index&.to_s, mode: rules.case, connection: connection)
        name = postgresql_constraint(error)
        return postgresql_target?(error, target) && identity?(name, target) if name

        named_in_message?(error.message.to_s, target)
      end

      private

      # SQLite names the columns, or the index of an expression; MySQL the key.
      def named_in_message?(message, target)
        if (match = SQLITE_COLUMNS.match(message))
          match[:columns].split(",").map(&:strip) == ["#{target.bare_table}.#{target.column}"] &&
            on_the_column_alone?(target)
        elsif (match = SQLITE_INDEX.match(message) || MYSQL_KEY.match(message))
          same_table?(match, target) && identity?(match[:name], target)
        else
          false
        end
      end

      # The constraint name from PostgreSQL's diagnostics (PG_DIAG_CONSTRAINT_NAME),
      # or from the message when the error carries no result.
      def postgresql_constraint(error)
        field = diagnostic(error, :PG_DIAG_CONSTRAINT_NAME)
        return field if field

        POSTGRESQL_CONSTRAINT.match(error.message.to_s)&.[](:name)
      end

      # A violation reported on another table (a trigger writing elsewhere),
      # or on a same-named table in another schema, is not ours, whatever its
      # index is called.
      def postgresql_target?(error, target)
        table = diagnostic(error, :PG_DIAG_TABLE_NAME)
        schema = diagnostic(error, :PG_DIAG_SCHEMA_NAME)
        wanted_schema = target.table.split(".")[-2]
        (table.nil? || table == target.bare_table) && (schema.nil? || wanted_schema.nil? || schema == wanted_schema)
      end

      def diagnostic(error, field)
        result = error.cause.try(:result)
        return unless result && defined?(::PG) && ::PG.const_defined?(field)

        result.error_field(::PG.const_get(field))
      end

      # A MySQL key names its table only from 8.0.19 on; SQLite's index form never does.
      def same_table?(match, target)
        reported = match[:table] if match.names.include?("table")
        reported.nil? || reported == target.bare_table
      end

      def identity?(name, target)
        return true if known_name?(name, target)

        reading(target) do |connection, contract|
          found = connection.indexes(target.table).find { |index| index.name == name }
          found ? contract.satisfied_by?(found) : false
        end
      end

      # SQLite's "UNIQUE constraint failed: users.username": some unique
      # index on exactly that column was violated; it is ours when one such
      # index is the identity index.
      def on_the_column_alone?(target)
        reading(target) do |connection, contract|
          connection.indexes(target.table).any? do |index|
            index.unique && Array(index.columns) == [target.column] &&
              (known_name?(index.name, target) || contract.satisfied_by?(index))
          end
        end
      end

      def known_name?(name, target)
        name == target.index || gem_index_names(target).include?(name)
      end

      def gem_index_names(target)
        %i[lowercase preserve].map do |mode|
          Comparison.index_definition(adapter: :sqlite, table: target.table, column: target.column, mode: mode)[:name]
        end
      end

      # Reading indexes back can fail (a permissions quirk, a dropped
      # connection); then only the names above are recognised, and the error
      # propagates.
      def reading(target)
        with_connection(target) do |connection|
          yield connection, Comparison::IndexContract.new(connection, table: target.table, column: target.column,
                                                                      mode: target.mode)
        end
      rescue StandardError
        false
      end

      def with_connection(target, &)
        return yield(target.connection) if target.connection

        ActiveRecord::Base.with_connection(&)
      end
    end
  end
end
