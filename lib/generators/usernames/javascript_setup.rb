# frozen_string_literal: true

module Usernames
  module Generators
    # Whether `import "usernames"` can work in the app being installed into,
    # for `rails generate usernames:install`: importmap (nothing else
    # resolves the specifier), an app/javascript/application.js entrypoint,
    # and stimulus-rails' controllers/application.js exporting the
    # `application` the gem's index.js registers on. :nodoc:
    module JavascriptSetup
      APPLICATION_JS = "app/javascript/application.js"
      STIMULUS_APPLICATION = "app/javascript/controllers/application.js"
      IMPORTED = /^\s*import\s+["']usernames["']/
      EXPORTS_APPLICATION = /export\s*(?:\{[^}]*\bapplication\b[^}]*\}|(?:const|let|var)\s+application\b)/

      private

      # :ready, :imported, or what is missing for the line to work. Read
      # once, before the line is added, so the message can say it was.
      def javascript_setup
        @javascript_setup ||=
          if !File.exist?(destination("config/importmap.rb")) then :no_importmap
          elsif !File.exist?(destination(APPLICATION_JS)) then :no_entrypoint
          elsif File.read(destination(APPLICATION_JS)).match?(IMPORTED) then :imported
          elsif !stimulus_application? then :no_stimulus
          else :ready
          end
      end

      def stimulus_application?
        path = destination(STIMULUS_APPLICATION)
        File.exist?(path) && File.read(path).match?(EXPORTS_APPLICATION)
      end

      def destination(path) = File.join(destination_root, path)
    end
  end
end
