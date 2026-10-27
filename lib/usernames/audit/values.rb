# frozen_string_literal: true

module Usernames
  class Audit
    # What one pass over the stored values finds. Collision groups are keyed
    # by comparison_key(normalize(stored)), over non-nil values only: an
    # absent username is not an identity, and never collides.
    class Values
      attr_reader :noncanonical, :failing, :total

      def initialize(rules)
        @rules = rules
        @noncanonical = []
        @groups = Hash.new { |hash, key| hash[key] = [] }
        @failing = []
        @total = 0
      end

      def <<((id, value))
        @total += 1
        canonical = @rules.normalize(value)
        @noncanonical << [id, value, canonical] unless canonical == value
        @groups[@rules.comparison_key(canonical)] << [id, value]
        failure = canonical.empty? ? :blank : @rules.failure_for(canonical)&.reason
        @failing << [id, value, failure] if failure
        self
      end

      def collisions
        @groups.select { |_key, rows| rows.size > 1 }.to_a
      end
    end
  end
end
