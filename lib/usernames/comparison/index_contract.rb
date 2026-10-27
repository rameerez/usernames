# frozen_string_literal: true

require_relative "index_expression"

module Usernames
  module Comparison
    # Whether an index read back from the database enforces the comparison
    # contract for one column — the one question the installer (is the index
    # already there?), the audit (does the database enforce uniqueness?) and
    # UniqueViolation (was the violated index the username's?) all ask, so
    # they can never disagree.
    #
    #   contract = IndexContract.new(connection, table: "users", column: :username, mode: :lowercase)
    #   contract.violation(index)       # => nil, or why not: "only covers rows WHERE (active = 1)"
    #   contract.satisfied_by?(index)   # => true / false
    #
    # It is a recogniser, not a normaliser: the index is read as SQL
    # (IndexExpression) and has to be one of the few shapes the gem's own
    # index takes as each database prints it back; anything else does not
    # count, however much it looks like one.
    #
    #                lowercase mode                  preserve mode
    #   PostgreSQL   username, (username)::text      lower(username COLLATE "C"), lower((username)::text COLLATE "C")
    #   SQLite       username                        lower(username)
    #   MySQL        username                        lower(username)
    #
    # And it must be unique, valid, over every row and byte-compared:
    #
    # * unique over every row: a partial index (`WHERE active`) lets two
    #   inactive accounts share a name. `WHERE username IS NOT NULL` is the
    #   one condition that changes nothing, since an absent name is nobody's.
    # * exactly the key: `(tenant_id, username)` or `substr(username, 1, 3)`
    #   are unique indexes, but not on the identity.
    # * byte-wise: a `COLLATE NOCASE` index on SQLite, or a PostgreSQL index
    #   under a linguistic collation, decides "the same name" differently
    #   from Ruby. And in every mode but PostgreSQL's preserve (whose
    #   expression carries its own COLLATE "C"), the queries compare the
    #   column under the column's collation, so that one has to compare
    #   bytes too: a BINARY index on a NOCASE column takes `javi` and `JAVI`
    #   while `WHERE username = 'javi'` finds both.
    # * valid: PostgreSQL keeps an interrupted CREATE INDEX CONCURRENTLY as
    #   an invalid index that enforces nothing.
    class IndexContract
      # Collations that compare bytes, per adapter (SQLite's BINARY is the default).
      BYTEWISE = { sqlite: %w[binary], postgresql: %w[c posix], mysql: %w[utf8mb4_bin] }.freeze

      Expression = IndexExpression

      attr_reader :table, :column, :mode, :adapter

      # Whether a column under `collation` is compared the way `mode` needs
      # on `adapter` — the rule the audit's column check and violation share.
      # `collation` nil is the column's default: SQLite's BINARY, while
      # MySQL's default is the server's, which is not utf8mb4_bin.
      def self.column_collation_ok?(adapter, mode, collation)
        return true if mode == :preserve && adapter == :postgresql

        bytewise?(adapter, collation)
      end

      def self.bytewise?(adapter, collation)
        return adapter == :sqlite if collation.nil?

        BYTEWISE.fetch(adapter).include?(collation.downcase)
      end

      def initialize(connection, table:, column:, mode:)
        @connection = connection
        @table = table.to_s
        @column = column.to_s
        @mode = mode
        @adapter = Comparison.adapter(connection)
      end

      # The index the gem itself writes: what the installer adds.
      def definition
        @definition ||= Comparison.index_definition(adapter: adapter, table: table, column: column, mode: mode)
      end

      def satisfied_by?(index)
        violation(index).nil?
      end

      # nil when `index` enforces the contract, else why it does not.
      def violation(index)
        return "isn't unique" unless index.unique
        return "isn't valid (an interrupted concurrent build enforces nothing)" if index.try(:valid?) == false

        key_violation(index) || predicate_violation(index) || collation_violation(index)
      end

      # The collation the column itself compares under (nil: SQLite's
      # default BINARY). On PostgreSQL a column without one has the
      # database's. SQLite keeps its CREATE TABLE as written, and Active
      # Record reads a collation back from it only when quoted — to it
      # `username VARCHAR COLLATE NOCASE` has none — so there the definition
      # itself is read.
      def column_collation
        found = @connection.columns(table).find { |each| each.name == column }&.collation
        return found if found
        return sqlite_column_collation if adapter == :sqlite
        return unless postgresql?

        @connection.select_value("SELECT datcollate FROM pg_database WHERE datname = current_database()")
      end

      # Whether `index` involves the column at all, so the audit lists it.
      def mentions?(index)
        columns = index.columns
        return Array(columns).map(&:to_s).include?(column) unless columns.is_a?(String)

        Expression.names(columns).any? { |name| name.named?(column) }
      end

      private

      def expected_key
        definition[:column].to_s
      end

      def postgresql?
        adapter == :postgresql
      end

      # Active Record reads a plain index back as its columns, and an
      # expression as the database prints it.
      def key_violation(index)
        columns = index.columns
        unless columns.is_a?(String)
          return if mode == :lowercase && Array(columns).map(&:to_s) == [column]

          return "is on #{Array(columns).join(', ')}, not #{expected_key}"
        end

        node = Expression.parse(columns)
        return "is on an unsupported expression: #{columns}" unless node

        "is on #{columns}, not #{expected_key}" unless expected_key?(node)
      end

      def expected_key?(node)
        if mode == :lowercase
          column?(node, cast: postgresql?)
        elsif postgresql?
          node.is_a?(Expression::Lower) && node.operand.is_a?(Expression::Collate) &&
            node.operand.collation == "C" && column?(node.operand.operand, cast: true)
        else
          node.is_a?(Expression::Lower) && column?(node.operand, cast: false)
        end
      end

      def column?(node, cast:)
        node = node.operand if cast && node.is_a?(Expression::Cast)
        node.is_a?(Expression::Column) && node.named?(column)
      end

      def predicate_violation(index)
        return if index.where.blank?

        node = Expression.parse(index.where)
        return if node.is_a?(Expression::NotNull) && column?(node.operand, cast: false)

        "only covers rows WHERE #{index.where}"
      end

      # The index's own collations, then the column's: in every mode but
      # PostgreSQL's preserve the queries compare the column under its own
      # collation, whatever the index says.
      def collation_violation(index)
        own = collations_in(index_sql(index)).find { |name| !self.class.bytewise?(adapter, name) }
        return "compares under collation #{own.inspect}, not byte by byte" if own

        collation = column_collation
        return if self.class.column_collation_ok?(adapter, mode, collation)

        "is on a column compared under collation #{collation.inspect}, not byte by byte"
      end

      # Every name that follows a COLLATE in the index's own SQL.
      def collations_in(sql)
        tokens = sql.is_a?(Array) ? sql : Expression.tokens(sql)
        tokens.each_cons(2).filter_map do |(kind, text), (_, name)|
          name if kind == :word && text.casecmp?("collate")
        end
      end

      def sqlite_column_collation
        sql = @connection.select_value("SELECT sql FROM sqlite_master WHERE type = 'table' " \
                                       "AND name = #{@connection.quote(table.split('.').last)}")
        definitions = column_definitions(Expression.tokens(sql))
        definition = definitions.find { |tokens| Expression.name(tokens.first)&.named?(column) }
        collations_in(outside_parentheses(definition.to_a)).last
      end

      # A column definition without whatever its parentheses hold: only a
      # COLLATE at its own level is the column's collation. One inside
      # CHECK (...), DEFAULT (...) or GENERATED ALWAYS AS (...) collates that
      # expression alone, and a type's VARCHAR(255) holds none. Quoted names
      # and string literals are single tokens, so a parenthesis inside one
      # does not count.
      def outside_parentheses(tokens)
        depth = 0
        tokens.select do |token|
          depth -= 1 if token == [:symbol, ")"]
          outside = depth.zero? && !token.in?([[:symbol, "("], [:symbol, ")"]])
          depth += 1 if token == [:symbol, "("]
          outside
        end
      end

      # The comma-separated definitions inside CREATE TABLE's parentheses,
      # each as its tokens.
      def column_definitions(tokens)
        definitions = [[]]
        depth = 0
        tokens.each do |token|
          depth -= 1 if token == [:symbol, ")"]
          if depth == 1 && token == [:symbol, ","] then definitions << []
          elsif depth >= 1 then definitions.last << token
          end
          depth += 1 if token == [:symbol, "("]
        end
        definitions
      end

      # The index as the database itself prints it: Active Record reads back
      # neither an index's collation nor whether a column in it has one.
      def index_sql(index)
        case adapter
        when :sqlite
          @connection.select_value("SELECT sql FROM sqlite_master WHERE type = 'index' " \
                                   "AND name = #{@connection.quote(index.name)}")
        when :postgresql
          qualified = [*table.split(".")[0...-1], index.name].join(".")
          @connection.select_value("SELECT pg_get_indexdef(#{@connection.quote(@connection.quote_table_name(qualified))}" \
                                   "::regclass)")
        end
      end
    end
  end
end
