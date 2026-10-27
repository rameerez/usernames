# frozen_string_literal: true

require "rails/generators/base"

module Usernames
  module Generators
    # rails generate usernames:availability [--model=User] [--column=username]
    #
    # Copies a live "is this name free?" check into the app:
    # nothing is mounted behind its back, and every file is the app's to edit.
    #
    #   app/controllers/usernames/availability_controller.rb   GET /usernames/availability?<column>=…
    #   app/javascript/controllers/username_check_controller.js
    #   app/views/usernames/_field.html.erb                     <%= render "usernames/field", form: form %>
    class AvailabilityGenerator < Rails::Generators::Base
      source_root File.expand_path("templates/availability", __dir__)

      desc "Copy a rate-limited availability endpoint, a Stimulus controller and a form partial into your app."

      class_option :model, type: :string, default: "User", desc: "The model with has_username"
      class_option :column, type: :string, default: "username", desc: "Its username column"

      def create_controller
        template "availability_controller.rb.tt", "app/controllers/usernames/availability_controller.rb"
      end

      # Thor injects a line only once, so a re-run leaves routes.rb alone.
      def add_route
        route %(get "usernames/availability", to: "usernames/availability#show", as: :usernames_availability)
      end

      def create_stimulus_controller
        template "username_check_controller.js.tt", "app/javascript/controllers/username_check_controller.js"
      end

      def create_partial
        template "_field.html.erb.tt", "app/views/usernames/_field.html.erb"
      end

      def display_post_install_message
        say "\n\tThe `usernames` availability check has been successfully installed!", :green
        say "\nTo complete the setup:"
        say "  1. Render the field in your sign-up form: <%= render \"usernames/field\", form: form %>"
        say "  2. If you don't use importmap's eagerLoadControllersFrom, register the Stimulus controller " \
            "(rails stimulus:manifest:update)."
        say "  3. Give production a shared cache store (Solid Cache, Redis or Memcached). With the NullStore, " \
            "Rails' rate_limit counts nothing, so the endpoint answers 503 there until you do."
        say "\nThe route is declared at the top of config/routes.rb, so a catch-all /:#{column} below it can't shadow it."
        say "Hints in the browser never block submission: the model and its unique index decide.", :green
      end

      private

      def model_name
        options[:model].camelize
      end

      def singular
        model_name.underscore.tr("/", "_")
      end

      def column
        options[:column].to_s
      end
    end
  end
end
