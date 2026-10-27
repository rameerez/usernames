# frozen_string_literal: true

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
    # An index enforces it when it is unique, valid, on exactly the column (or
    # exactly the comparison expression), over every row, and compares bytes:
    #
    # * unique over every row: a partial index (`WHERE active`) lets two
    #   inactive accounts share a name. `WHERE username IS NOT NULL` is the
    #   one condition that changes nothing, since an absent name is nobody's.
    # * exactly the key: `(tenant_id, username)` or `substr(username, 1, 3)`
    #   are unique indexes, but not on the identity.
    # * byte-wise: a `COLLATE NOCASE` index on SQLite, or a PostgreSQL index
    #   under a linguistic collation, decides "the same name" differently
    #   from Ruby. On PostgreSQL that is the index's own collation, else the
    #   column's, else the database's.
    # * valid: PostgreSQL keeps an interrupted CREATE INDEX CONCURRENTLY as
    #   an invalid index that enforces nothing.
    class IndexContract
      # Collations that compare bytes, per adapter (SQLite's BINARY is the default).
      BYTEWISE = { sqlite: %w[binary], postgresql: %w[c posix], mysql: %w[utf8mb4_bin] }.freeze

      COLLATE = /\bCOLLATE\s+"?([^\s"()]+)"?/i

      attr_reader :table, :column, :mode, :adapter

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
        return "is on #{Array(index.columns).join(', ')}, not #{expected_key}" unless same_key?(index)
        return "only covers rows WHERE #{index.where}" unless every_row?(index)

        collation_violation(index)
      end

      # Whether `index` involves the column at all, so the audit lists it.
      def mentions?(index)
        columns = index.columns
        return Array(columns).map(&:to_s).include?(column) unless columns.is_a?(String)

        columns.match?(/(?<![\w$])"?#{Regexp.escape(column)}"?(?![\w$])/)
      end

      private

      def expected_key
        definition[:column].to_s
      end

      # The database spells an expression its own way — PostgreSQL reads
      # `lower(username COLLATE "C")` back as `lower(((username)::text
      # COLLATE "C"))` — so both are reduced to their letters first.
      def same_key?(index)
        wanted = definition[:column]
        return index.columns == [wanted.to_s] if wanted.is_a?(Symbol)

        index.columns.is_a?(String) && squeeze(index.columns) == squeeze(wanted)
      end

      def every_row?(index)
        index.where.blank? || squeeze(index.where) == squeeze("#{column} IS NOT NULL")
      end

      def collation_violation(index)
        bytewise = BYTEWISE.fetch(adapter)
        collation = effective_collation(index)
        return if collation.nil? || bytewise.include?(collation.downcase)

        "compares under collation #{collation.inspect}, not byte by byte"
      end

      # What the index compares under. In preserve mode on PostgreSQL the key
      # itself is `lower(column COLLATE "C")` (checked above), so only an
      # extra collation on the index could change it.
      def effective_collation(index)
        own = collations_in(index_sql(index)).reject { |name| preserve_c?(name) }
        return own.first if own.any?
        return if mode == :preserve && adapter == :postgresql

        column_collation
      end

      def preserve_c?(name)
        mode == :preserve && adapter == :postgresql && name.casecmp?("C")
      end

      def collations_in(sql)
        sql.to_s.scan(COLLATE).flatten
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

      def column_collation
        found = @connection.columns(table).find { |each| each.name == column }&.collation
        return found if found || adapter != :postgresql

        @connection.select_value("SELECT datcollate FROM pg_database WHERE datname = current_database()")
      end

      def squeeze(expression)
        expression.to_s.downcase.gsub(/::(text|character varying)/, "").gsub(/[\s"`()]/, "")
      end
    end
  end
end
