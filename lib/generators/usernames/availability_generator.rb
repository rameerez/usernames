# frozen_string_literal: true

require "rails/generators/base"

module Usernames
  module Generators
    # rails generate usernames:availability [--copy] [--model=User] [--column=username]
    #
    # The live "is this name free?" check is built in: the gem's endpoint,
    # its route and its Stimulus controller, used by `f.username_field`. On
    # its own this generator says so, and — when it finds the files a 0.1
    # install copied into the app — what to do with them.
    #
    # --copy writes a set of your own to change, which replaces the gem's:
    #
    #   app/controllers/usernames/availability_controller.rb   the endpoint (the gem's class, overridden)
    #   app/javascript/controllers/username_check_controller.js
    #   app/views/usernames/_field.html.erb                     <%= render "usernames/field", form: form %>
    #   config/routes.rb                                         usernames_availability, at the top
    class AvailabilityGenerator < Rails::Generators::Base
      source_root File.expand_path("templates/availability", __dir__)

      desc "Explain the built-in availability check, or copy it into your app (--copy) to customise it."

      class_option :copy, type: :boolean, default: false, desc: "Copy the endpoint, the JavaScript and a partial"
      class_option :model, type: :string, default: "User", desc: "The model with has_username"
      class_option :column, type: :string, default: "username", desc: "Its username column"

      GEM = File.expand_path("../../..", __dir__)
      CONTROLLER = "app/controllers/usernames/availability_controller.rb"
      JAVASCRIPT = "app/javascript/controllers/username_check_controller.js"
      PARTIAL = "app/views/usernames/_field.html.erb"
      ROUTES = "config/routes.rb"

      # Read before anything is written, so --copy's own files are not mistaken for 0.1's.
      def look_for_copied_files
        @found = [CONTROLLER, JAVASCRIPT, PARTIAL].select { |path| File.exist?(File.join(destination_root, path)) }
        @found << ROUTES if routes.include?("usernames/availability#show")
      end

      def copy_the_endpoint
        return unless options[:copy]

        create_file CONTROLLER, copied("#", File.read(File.join(GEM, CONTROLLER), encoding: "UTF-8"))
      end

      def copy_the_javascript
        return unless options[:copy]

        source = File.join(GEM, "app/assets/javascripts/usernames/username_check_controller.js")
        create_file JAVASCRIPT, copied("//", File.read(source, encoding: "UTF-8"))
      end

      def copy_the_partial
        template "_field.html.erb.tt", PARTIAL if options[:copy]
      end

      # Above every other route, so a catch-all can't shadow it; the engine
      # then draws none. Thor injects a line only once.
      def draw_the_route
        route "usernames_availability" if options[:copy]
      end

      def display_post_install_message
        options[:copy] ? copied_message : built_in_message
        upgrade_message unless @found.empty? || options[:copy]
      end

      private

      def built_in_message
        say "\n\tThe availability check is built into the usernames gem: nothing to generate.", :green
        say "\n  <%= f.username_field :#{column} %> <%= f.username_status :#{column} %>   in the form"
        say %(  import "usernames"                                   in app/javascript/application.js)
        say %(  config.availability.targets = { #{target_alias.inspect} => "#{model_name}##{column}" }   in the initializer)
        say "\nTo change how it works, copy it into your app: rails generate usernames:availability --copy"
      end

      # A 0.1 install copied a controller, a route, a Stimulus controller and
      # a partial that speak an older protocol. Either mode keeps the pair
      # consistent; mixing them does not.
      def upgrade_message
        say "\nFound files a 0.1 install copied into this app: #{@found.join(', ')}.", :yellow
        say "They speak the 0.1 protocol, and the app's copies win over the gem's. Pick one:"
        say "  * Managed (recommended): delete them all — the controller, the usernames/availability route, " \
            "the Stimulus controller and the partial — and use f.username_field / f.username_status with " \
            "`import \"usernames\"`. Upgrades then come with the gem."
        say "  * Customized: keep your pair, and set config.availability.path = nil so the gem draws no route. " \
            "Don't `import \"usernames\"`: your Stimulus controller is the one registered as username-check."
      end

      def copied_message
        say "\n\tThe availability check is now yours to change.", :green
        say "\n  #{CONTROLLER} replaces the gem's endpoint (same class); `usernames_availability` in config/routes.rb " \
            "draws its route, above any catch-all, so the gem draws none."
        say "  #{JAVASCRIPT} is registered by your Stimulus setup as username-check: remove " \
            "`import \"usernames\"` from app/javascript/application.js, or the gem's would register over it."
        say %(  Render the field with <%= render "usernames/field", form: form %>.)
        say "  The endpoint answers for config.availability.targets, as the gem's did: keep " \
            "{ #{target_alias.inspect} => \"#{model_name}##{column}\" } there."
        say "Gem upgrades no longer change these files: compare them with the gem's when you upgrade.", :yellow
      end

      def copied(comment, source)
        note = "#{comment} Copied from the usernames gem by `rails generate usernames:availability --copy`. " \
               "It's yours: edit it.\n"
        source.start_with?("# frozen_string_literal") ? source.sub("\n", "\n\n#{note}") : note + source
      end

      def routes
        path = File.join(destination_root, ROUTES)
        File.exist?(path) ? File.read(path) : ""
      end

      def model_name
        options[:model].camelize
      end

      def target_alias
        model_name.underscore.tr("/", "_")
      end

      def column
        options[:column].to_s
      end
    end
  end
end
