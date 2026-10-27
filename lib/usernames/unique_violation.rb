# frozen_string_literal: true

module Usernames
  # Whether an ActiveRecord::RecordNotUnique came from the username's unique
  # index, or from some other one (D-19).
  #
  # A duplicate email raises exactly the same exception class as a duplicate
  # username. Redrawing a generated name over an email clash would loop for
  # nothing, and reporting it as "username has already been taken" would be
  # a lie that hides a real error — so the race wrapper asks this first, and
  # anything that is not the username's index propagates untouched.
  #
  # Each adapter names the culprit differently:
  #
  #   PostgreSQL  the constraint name, from the server's error diagnostics
  #   MySQL       Duplicate entry 'javi' for key 'users.index_users_on_username'
  #   SQLite      UNIQUE constraint failed: users.username
  #               UNIQUE constraint failed: index 'index_users_on_lower_username'
  #
  # An index name is then confirmed against the table's own indexes (does it
  # cover this column?), or accepted when it is one the gem names itself or
  # the app configured as `unique_index`.
  module UniqueViolation
    POSTGRESQL_CONSTRAINT = /unique constraint "(?<name>[^"]+)"/
    MYSQL_KEY = /for key '(?:(?<table>[^'.]+)\.)?(?<name>[^']+)'/
    SQLITE_COLUMNS = /UNIQUE constraint failed: (?<columns>[^:']+?)\s*\z/
    SQLITE_INDEX = /UNIQUE constraint failed: index '(?<name>[^']+)'/

    # What a violation is matched against. :nodoc:
    Target = ::Data.define(:table, :column, :index, :connection)

    class << self
      # UniqueViolation.of?(error, table: "users", column: :username)
      #
      # `index` is config.unique_index (an index the generator did not
      # create); `connection` reads the table's indexes back.
      # NOTE(p3): `index:` and `connection:` are additions to the PRD §11.3
      # signature: the model passes its own connection (an app may have
      # several databases) and the configured index name.
      def of?(error, table:, column:, index: nil, connection: nil)
        target = Target.new(table: table.to_s.split(".").last, column: column.to_s, index: index&.to_s,
                            connection: connection)
        name = postgresql_constraint(error)
        return postgresql_table?(error, target.table) && index_on?(name, target) if name

        named_in_message?(error.message.to_s, target)
      end

      # A unique index on the column itself (`["username"]`), or an expression
      # over it (`lower(((username)::text COLLATE "C"))`). :nodoc:
      def covers?(index, column)
        columns = index.columns
        column = column.to_s
        if columns.is_a?(String)
          columns.match?(/(?<![\w$])"?#{Regexp.escape(column)}"?(?![\w$])/)
        else
          Array(columns).map(&:to_s).include?(column)
        end
      end

      private

      # SQLite names the columns, or the index of an expression; MySQL the key.
      def named_in_message?(message, target)
        if (match = SQLITE_COLUMNS.match(message))
          match[:columns].split(",").map(&:strip).include?("#{target.table}.#{target.column}")
        elsif (match = SQLITE_INDEX.match(message) || MYSQL_KEY.match(message))
          same_table?(match, target) && index_on?(match[:name], target)
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

      # A violation reported on another table (a trigger writing elsewhere)
      # is not ours, whatever its index is called.
      def postgresql_table?(error, table)
        reported = diagnostic(error, :PG_DIAG_TABLE_NAME)
        reported.nil? || reported == table
      end

      def diagnostic(error, field)
        result = error.cause.try(:result)
        return unless result && defined?(::PG) && ::PG.const_defined?(field)

        result.error_field(::PG.const_get(field))
      end

      # A MySQL key names its table only from 8.0.19 on; SQLite's index form never does.
      def same_table?(match, target)
        reported = match[:table] if match.names.include?("table")
        reported.nil? || reported == target.table
      end

      def index_on?(name, target)
        return true if name == target.index
        return true if gem_index_names(target.table, target.column).include?(name)

        found = indexes(target.connection, target.table).find { |index| index.name == name }
        found ? covers?(found, target.column) : false
      end

      def gem_index_names(table, column)
        %i[lowercase preserve].map do |mode|
          Comparison.index_definition(adapter: :sqlite, table: table, column: column, mode: mode)[:name]
        end
      end

      # Reading indexes back can fail (no connection, a permissions quirk);
      # then only the names above are recognised, and the error propagates.
      def indexes(connection, table)
        return connection.indexes(table) if connection

        ActiveRecord::Base.with_connection { |default| default.indexes(table) }
      rescue StandardError
        []
      end
    end
  end
end
