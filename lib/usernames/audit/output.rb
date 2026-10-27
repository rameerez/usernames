# frozen_string_literal: true

module Usernames
  class Audit
    # How the audit writes: a section per subject, ✓ for what is fine, ✗ for
    # a problem (counted), · for a note, and at most EXAMPLES rows per finding.
    module Output
      private

      def list(rows, clean, found, &)
        return ok(clean) if rows.empty?

        problem("#{format(found, rows.size)}:")
        rows.first(EXAMPLES).each { |row| line "      #{yield(*row)}" }
        more(rows)
      end

      def more(rows)
        line "      … and #{rows.size - EXAMPLES} more" if rows.size > EXAMPLES
      end

      def finish
        line ""
        if @problems.zero?
          line "Nothing to fix: the database enforces the same uniqueness the gem checks."
        else
          line "#{@problems} #{@problems == 1 ? 'thing' : 'things'} to fix. See the README, \"Adopting an existing column\"."
        end
        @problems
      end

      def section(title)
        line ""
        line title
      end

      def ok(message)
        line "  ✓ #{message}"
      end

      def problem(message)
        @problems += 1
        line "  ✗ #{message}"
      end

      def line(text)
        @io.puts(text)
      end
    end
  end
end
