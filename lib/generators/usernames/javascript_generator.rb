# frozen_string_literal: true

require "rails/generators/base"

module Usernames
  module Generators
    # rails generate usernames:javascript
    #
    # For an app that bundles its JavaScript (jsbundling, esbuild, Vite…)
    # rather than using importmap, where `import "usernames"` has nothing to
    # resolve it: copies the gem's Stimulus controller to
    # app/javascript/controllers/username_check_controller.js, where the
    # bundler and Stimulus' manifest pick it up. From then on the file is
    # the app's: run this again after a gem upgrade to refresh it.
    class JavascriptGenerator < Rails::Generators::Base
      desc "Copy the username-check Stimulus controller into app/javascript/controllers (for jsbundling apps)."

      SOURCE = File.expand_path("../../../app/assets/javascripts/usernames/username_check_controller.js", __dir__)
      DESTINATION = "app/javascript/controllers/username_check_controller.js"

      def copy_the_controller
        note = "// Copied from the usernames gem #{Usernames::VERSION} by `rails generate usernames:javascript`. " \
               "Run it again after upgrading the gem.\n"
        create_file DESTINATION, note + File.read(SOURCE, encoding: "UTF-8")
      end

      def display_post_install_message
        say "\n\t#{DESTINATION} is in place.", :green
        say "\nRegister it as username-check: `rails stimulus:manifest:update`, or in " \
            "app/javascript/controllers/index.js:"
        say %(  import UsernameCheckController from "./username_check_controller"\n) +
            %(  application.register("username-check", UsernameCheckController))
        say "Then f.username_field / f.username_status work as with importmap. The file is the app's now: " \
            "the gem's fields and endpoint change with the gem, so refresh it when you upgrade.", :yellow
      end
    end
  end
end
