# frozen_string_literal: true

module Usernames
  module Generators
    # What the database holds now for one table and column, as the install
    # generator sees it: the column (nil when missing), the table's indexes,
    # and whether any row already has a username.
    #
    # Every lookup is guarded: a generator must run without a database (a
    # fresh checkout, CI, a laptop with the server off). Then nothing is known,
    # and the column is assumed missing.
    class ExistingSchema
      attr_reader :column, :indexes

      # `owner` is the model (or ActiveRecord::Base) whose database holds the
      # table; `mode` is the case mode the index is for: the first index that
      # enforces its comparison contract is the matching one. Every other
      # index involving the column is kept with why it does not count.
      def self.read(owner, table, column, mode)
        owner.with_connection do |connection|
          next new(reachable: true) unless connection.table_exists?(table)

          existing = connection.columns(table).find { |each| each.name == column.to_s }
          indexes = connection.indexes(table)
          contract = Usernames::Comparison::IndexContract.new(connection, table: table, column: column, mode: mode)
          new(reachable: true, column: existing, indexes: indexes,
              verdicts: verdicts(indexes, contract),
              populated: !existing.nil? && rows?(connection, table, column))
        end
      rescue StandardError
        new(reachable: false)
      end

      # The migration line that drops `index` (one of `indexes`) and can be
      # rolled back: it restates the columns or expression as the database
      # reads them back, the uniqueness and the condition.
      def self.remove_index_line(table, index)
        columns = index.columns
        options = [columns.is_a?(Array) ? "column: #{columns.map(&:to_sym).inspect}" : columns.inspect]
        options << "unique: true" if index.unique
        options << "where: #{index.where.inspect}" if index.where.present?
        options << "name: #{index.name.inspect}"
        "remove_index #{Usernames::Comparison.ruby_name(table)}, #{options.join(', ')}"
      end

      # [[index, reason], …] for every index involving the column; reason nil
      # when it enforces the contract.
      def self.verdicts(indexes, contract)
        indexes.select { |index| contract.mentions?(index) }.map { |index| [index, contract.violation(index)] }
      end

      def self.rows?(connection, table, column)
        sql = "SELECT 1 FROM #{connection.quote_table_name(table)} " \
              "WHERE #{connection.quote_column_name(column)} IS NOT NULL LIMIT 1"
        !connection.select_value(sql).nil?
      end

      def initialize(reachable:, column: nil, indexes: [], verdicts: [], populated: false)
        @reachable = reachable
        @column = column
        @indexes = indexes
        @verdicts = verdicts
        @populated = populated
      end

      # The first index that enforces the contract, or nil.
      def matching_index
        @verdicts.find { |_index, reason| reason.nil? }&.first
      end

      # [[index, reason], …]: the indexes on the column that do not.
      def rejected_indexes
        @verdicts.select { |_index, reason| reason }
      end

      def reachable?
        @reachable
      end

      def populated?
        @populated
      end
    end
  end
end
