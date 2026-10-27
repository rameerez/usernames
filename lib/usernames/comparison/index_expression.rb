# frozen_string_literal: true

require "strscan"

module Usernames
  module Comparison
    # An index key or condition as the database prints it back, read as SQL
    # rather than as letters: `"user name"` is one identifier and `username`
    # another, and `"usernameisnotnull"` is a column, not `username IS NOT
    # NULL` with the spaces taken out.
    #
    # It understands only what an index enforcing the comparison contract
    # can contain, and nothing else parses (another function, an operator, a
    # literal, a second argument):
    #
    #   username  "username"  `username`  [username]   a column
    #   (username)::text  username::character varying   a PostgreSQL cast
    #   username COLLATE "C"                            a collation
    #   lower(username)                                 lower()
    #   username IS NOT NULL                            a null test
    #
    # Parentheses group without changing the meaning, so PostgreSQL's
    # `lower(((username)::text COLLATE "C"))` reads as
    # Lower(Collate(Cast(Column), "C")).
    #
    #   IndexExpression.parse('lower("user name")')  # => Lower(Column("user name"))
    #   IndexExpression.parse("substr(username, 1, 3)")  # => nil
    module IndexExpression
      # A column, as written: quoted (compared exactly) or bare (compared
      # ignoring case, as every supported database folds a bare identifier).
      Column = ::Data.define(:name, :quoted) do
        def named?(column)
          quoted ? name == column : name.casecmp?(column)
        end
      end
      Cast = ::Data.define(:operand)
      Collate = ::Data.define(:operand, :collation)
      Lower = ::Data.define(:operand)
      NotNull = ::Data.define(:operand)

      NAMES = %i[identifier word].freeze
      KEYWORDS = %w[is not null collate].freeze
      CAST_TYPES = [%w[text], %w[varchar], %w[character varying]].freeze

      class << self
        # The parsed expression, or nil when it is anything else.
        def parse(sql)
          Parser.new(tokens(sql)).parse
        end

        # Every name in `sql`, keyword or not, as a Column.
        def names(sql)
          tokens(sql).filter_map { |kind, text| Column.new(text, kind == :identifier) if NAMES.include?(kind) }
        end

        # [kind, text] pairs: :identifier (quoted, unquoted), :word (bare),
        # :literal and :symbol. Whitespace only separates.
        def tokens(sql)
          scanner = StringScanner.new(sql.to_s)
          found = []
          until scanner.eos?
            next if scanner.skip(/\s+/)

            found << token(scanner)
          end
          found
        end

        private

        def token(scanner)
          if scanner.scan(/"((?:[^"]|"")*)"/) then [:identifier, scanner[1].gsub('""', '"')]
          elsif scanner.scan(/`((?:[^`]|``)*)`/) then [:identifier, scanner[1].gsub("``", "`")]
          elsif scanner.scan(/\[([^\]]*)\]/) then [:identifier, scanner[1]]
          elsif scanner.scan(/[A-Za-z_][A-Za-z0-9_$]*/) then [:word, scanner.matched]
          elsif scanner.scan(/'(?:[^']|'')*'/) then [:literal, scanner.matched]
          else [:symbol, scanner.scan(/::|./m)]
          end
        end
      end

      # Recursive descent over the tokens; nil as soon as one does not fit.
      class Parser
        def initialize(tokens)
          @tokens = tokens
          @at = 0
        end

        def parse
          node = expression
          node if node && @at == @tokens.size
        end

        private

        def expression
          node = postfix
          return node unless node && word?("is")
          return unless word?("not", 1) && word?("null", 2)

          advance(3)
          NotNull.new(node)
        end

        # A term followed by any casts and collations.
        def postfix
          node = primary
          while node
            if symbol?("::")
              advance
              node = cast_type && Cast.new(node)
            elsif word?("collate")
              advance
              name = collation_name
              node = name && Collate.new(node, name)
            else
              return node
            end
          end
        end

        def primary
          if symbol?("(")
            advance
            closing(expression)
          elsif word?("lower") && symbol?("(", 1)
            advance(2)
            (operand = closing(expression)) && Lower.new(operand)
          else
            column
          end
        end

        def closing(node)
          return unless node && symbol?(")")

          advance
          node
        end

        def column
          kind, text = @tokens[@at]
          return unless kind == :identifier || (kind == :word && !KEYWORDS.include?(text.downcase))

          advance
          Column.new(text, kind == :identifier)
        end

        def cast_type
          type = CAST_TYPES.find { |words| words.each_with_index.all? { |word, offset| word?(word, offset) } }
          type && advance(type.size)
        end

        def collation_name
          kind, text = @tokens[@at]
          return unless NAMES.include?(kind)

          advance
          text
        end

        def word?(word, offset = 0)
          kind, text = @tokens[@at + offset]
          kind == :word && text.casecmp?(word)
        end

        def symbol?(symbol, offset = 0)
          @tokens[@at + offset] == [:symbol, symbol]
        end

        def advance(count = 1)
          @at += count
        end
      end
    end
  end
end
