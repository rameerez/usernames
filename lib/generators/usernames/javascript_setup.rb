# frozen_string_literal: true

module Usernames
  module Generators
    # Whether `import "usernames"` can work in the app being installed into,
    # for `rails generate usernames:install`: importmap (nothing else
    # resolves the specifier), an app/javascript/application.js entrypoint,
    # and stimulus-rails' controllers/application.js exporting the
    # `application` the gem's index.js imports by name. A static import of a
    # name a module doesn't export fails the whole entrypoint before any of
    # it runs, so anything short of a plain named export is a no. :nodoc:
    module JavascriptSetup
      APPLICATION_JS = "app/javascript/application.js"
      STIMULUS_APPLICATION = "app/javascript/controllers/application.js"
      IMPORTED = /^\s*import\s+["']usernames["']/

      # `export const application = …` (or let, var).
      EXPORTS_A_BINDING = /\bexport\s+(?:const|let|var)\s+application\b/

      # `export { … }`, with an optional `from "…"`: the list, to read.
      EXPORT_LISTS = /\bexport\s*\{([^}]*)\}/

      # One entry of such a list: `application`, `application as application`,
      # or `other as application` — whatever is exported under that name.
      EXPORTED_AS_APPLICATION = /\A(?:application|[\w$]+\s+as\s+application)\z/

      QUOTES = %w[' " `].freeze

      private

      # :ready, :imported, or what is missing for the line to work. Read
      # once, before the line is added, so the message can say it was.
      def javascript_setup
        @javascript_setup ||=
          if !File.exist?(destination("config/importmap.rb")) then :no_importmap
          elsif !File.exist?(destination(APPLICATION_JS)) then :no_entrypoint
          elsif code(APPLICATION_JS, strings: true).match?(IMPORTED) then :imported
          elsif !File.exist?(destination(STIMULUS_APPLICATION)) then :no_stimulus
          elsif !exports_application?(code(STIMULUS_APPLICATION)) then :no_application_export
          else :ready
          end
      end

      def exports_application?(source)
        source.match?(EXPORTS_A_BINDING) || source.scan(EXPORT_LISTS).flatten.any? do |list|
          list.split(",").any? { |entry| entry.strip.match?(EXPORTED_AS_APPLICATION) }
        end
      end

      # A file read as code, in one pass: each comment becomes one space
      # (so `export/* c */const` still reads as two words), each string or
      # template literal `""` (so `"export { application }"` exports
      # nothing, and the `//` in `"https://…"` starts no comment).
      # `strings: true` keeps '…' and "…" strings as written, to read an
      # import's specifier. Regular-expression literals are read as code:
      # nothing in a Stimulus setup file needs them told apart.
      def code(path, strings: false)
        source = File.read(destination(path), encoding: "UTF-8")
        code = +""
        index = 0
        while index < source.length
          finish = token_end(source, index)
          code << (finish ? token(source, index, finish, strings) : source[index])
          index = finish || (index + 1)
        end
        code
      end

      # Where the comment or literal starting at `index` ends, or nil for
      # any other character.
      def token_end(source, index)
        case source[index, 2]
        when "//" then source.index("\n", index) || source.length
        when "/*" then (finish = source.index("*/", index + 2)) ? finish + 2 : source.length
        else literal_end(source, index) if QUOTES.include?(source[index])
        end
      end

      def token(source, start, finish, strings)
        return " " if source[start] == "/"
        return source[start...finish] if strings && source[start] != "`"

        '""'
      end

      # Just past the literal opening at `start`: its closing quote, with
      # backslash escapes skipped. A '…' or "…" string ends at a line break
      # at the latest; a template's `${…}` is read as part of it.
      def literal_end(source, start)
        quote = source[start]
        index = start + 1
        while index < source.length
          return index + 1 if source[index] == quote
          return index if source[index] == "\n" && quote != "`"

          index += source[index] == "\\" ? 2 : 1
        end
        source.length
      end

      def destination(path) = File.join(destination_root, path)
    end
  end
end
