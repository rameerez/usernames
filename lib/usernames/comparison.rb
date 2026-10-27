# frozen_string_literal: true

require_relative "comparison/index_contract"

module Usernames
  # How the database compares two usernames (PRD §11.1).
  #
  # "The same name" has to mean one thing in Ruby, in the unique index and in
  # every query, or the validator says a name is free that the index then
  # refuses (or worse, the other way round). PostgreSQL's `=` and `lower()`
  # follow the column's collation — under a Turkish collation `I` lowercases
  # to `ı`, and a nondeterministic collation can ignore punctuation — so the
  # gem pins the comparison instead of inheriting it:
  #
  #                lowercase mode   preserve mode
  #   PostgreSQL   username         lower(username COLLATE "C")   (ASCII-only, exactly Ruby's downcase)
  #   SQLite       username         lower(username)               (SQLite's lower() is ASCII-only)
  #   MySQL        username         lower(username)               (experimental; the column is utf8mb4_bin)
  #
  # In lowercase mode the stored value is already canonical, so a plain `=` on
  # a byte-compared column ("C" / utf8mb4_bin / SQLite's BINARY) is the whole
  # contract, and an ordinary unique index serves it.
  #
  # The same expression builds the unique index, the uniqueness check and
  # every helper. It is only ever used as a BOUND predicate,
  #
  #   where("#{Comparison.sql(User, :username)} = ?", key)
  #
  # never as a hash key, which Active Record would quote as a column name.
  # It holds nothing but gem-written SQL and adapter-quoted identifiers; the
  # username is always the bind, so the database never lowercases it under
  # its own locale.
  module Comparison
    # The byte-wise collation the column needs, per adapter. SQLite's default
    # BINARY already is one.
    COLLATIONS = { postgresql: "C", mysql: "utf8mb4_bin" }.freeze

    class << self
      # The comparison expression for `column` of `model`, table-qualified so
      # it stays unambiguous inside a join. The case mode is the one the
      # model declared with has_username (or the configured one for a model
      # that only uses the validator).
      def sql(model, column)
        model.with_connection do |connection|
          quoted = "#{connection.quote_table_name(model.table_name)}.#{connection.quote_column_name(column)}"
          expression(adapter(connection), quoted, mode_for(model, column))
        end
      end

      # What the install generator passes to add_index:
      #
      #   index_definition(adapter: :postgresql, table: :users, column: :username, mode: :preserve)
      #   # => { column: 'lower(username COLLATE "C")', name: "index_users_on_lower_username", unique: true }
      #
      # The names are the gem's own: UniqueViolation recognises them even
      # when it cannot read the index back.
      def index_definition(adapter:, table:, column:, mode:)
        table = table.to_s.split(".").last
        if mode == :preserve
          { column: index_expression(adapter, column), name: "index_#{table}_on_lower_#{column}", unique: true }
        else
          { column: column.to_sym, name: "index_#{table}_on_#{column}", unique: true }
        end
      end

      # The collation the column itself needs for `mode`: "C" on PostgreSQL,
      # "utf8mb4_bin" on MySQL, nil on SQLite (whose default BINARY is the
      # contract). nil for PostgreSQL in preserve mode: the comparison
      # expression carries its own COLLATE "C", so the column keeps the
      # database's collation — and `ORDER BY username` keeps sorting the way
      # people read (a "C" column sorts every uppercase letter first).
      def column_collation(adapter, mode = :lowercase)
        adapter = self.adapter(adapter)
        return nil if mode == :preserve && adapter == :postgresql

        COLLATIONS[adapter]
      end

      # A table or column name as a migration argument: `:users` when it is
      # a plain identifier, else a string literal — `"public.users"`, never
      # the `:public.users` that does not parse.
      def ruby_name(name)
        name = name.to_s
        name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? ":#{name}" : name.inspect
      end

      # :postgresql, :mysql or :sqlite, from a connection or an adapter name
      # ("PostgreSQL", "postgis", "Mysql2", "Trilogy", "sqlite3").
      # Any other adapter raises ConfigurationError: the comparison contract
      # is written for these three, and guessing another database's
      # collation and lower() is how two people end up with one name.
      def adapter(connection_or_name)
        name = connection_or_name.respond_to?(:adapter_name) ? connection_or_name.adapter_name : connection_or_name
        case name.to_s
        when /postg/i then :postgresql
        when /mysql|trilogy|maria/i then :mysql
        when /sqlite/i then :sqlite
        else
          raise ConfigurationError, "usernames supports PostgreSQL, MySQL and SQLite; the #{name.to_s.inspect} adapter " \
                                    "has no comparison contract"
        end
      end

      # The case mode `column` of `model` is compared in.
      def mode_for(model, column)
        definition = model.try(:_usernames)&.[](column.to_sym)
        definition ? definition.mode : Usernames.configuration.case
      end

      private

      def expression(adapter, quoted, mode)
        return quoted unless mode == :preserve

        adapter == :postgresql ? %(lower(#{quoted} COLLATE "C")) : "lower(#{quoted})"
      end

      # As written in a migration: the bare column, and on MySQL the extra
      # parentheses a functional key part needs (8.0.13+).
      def index_expression(adapter, column)
        adapter = self.adapter(adapter)
        sql = expression(adapter, column.to_s, :preserve)
        adapter == :mysql ? "(#{sql})" : sql
      end
    end
  end
end
