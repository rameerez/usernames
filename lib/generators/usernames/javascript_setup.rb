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

      private

      # :ready, :imported, or what is missing for the line to work. Read
      # once, before the line is added, so the message can say it was.
      def javascript_setup
        @javascript_setup ||=
          if !File.exist?(destination("config/importmap.rb")) then :no_importmap
          elsif !File.exist?(destination(APPLICATION_JS)) then :no_entrypoint
          elsif code(APPLICATION_JS).match?(IMPORTED) then :imported
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

      # A file's code without its comments: a commented-out export or import
      # is not one.
      def code(path)
        File.read(destination(path)).gsub(%r{/\*.*?\*/}m, "").gsub(%r{//[^\n]*}, "")
      end

      def destination(path) = File.join(destination_root, path)
    end
  end
end
