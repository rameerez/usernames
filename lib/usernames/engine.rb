# frozen_string_literal: true

require_relative "form_helpers"
require_relative "routes"

module Usernames
  # Not isolated. What it wires into the app, and how to turn each piece off:
  #
  # * `has_username` on every Active Record model.
  # * Its config/locales, loaded BEFORE the app's — Rails puts engines first
  #   and the application last — so any key in the app's own locale files
  #   wins.
  # * The app's own routes reserved, re-read whenever they reload
  #   (config.reserve_routes = false turns it off).
  # * The availability endpoint, Usernames::AvailabilityController, at
  #   config.availability.path: one route appended after the app's own, and
  #   left out when the app already has one named usernames_availability
  #   (path = nil draws none).
  # * `f.username_field` / `f.username_status` on every form builder.
  # * With importmap-rails, the pins `usernames` and `usernames/username-check`;
  #   with Propshaft or Sprockets, the JavaScript behind them. `import
  #   "usernames"` in app/javascript/application.js is what uses them.
  # * A bad configuration value fails at boot, not at the first sign-up.
  #
  # The generators (`usernames:install`, `usernames:availability`,
  # `usernames:javascript`, `usernames:locale`) need no wiring: Rails finds
  # them in lib/generators/usernames/ on the load path.
  class Engine < ::Rails::Engine
    JAVASCRIPTS = %w[usernames/index.js usernames/username_check_controller.js].freeze

    initializer "usernames.active_record" do
      ActiveSupport.on_load(:active_record) { extend Usernames::Model }
    end

    initializer "usernames.form_helpers" do
      ActiveSupport.on_load(:action_view) { ActionView::Helpers::FormBuilder.include(Usernames::FormBuilder) }
    end

    # Once, before the routes are first drawn. The block runs on every
    # draw (and redraw in development), reading the configuration as it is
    # by then.
    initializer "usernames.routes" do |app|
      ActionDispatch::Routing::Mapper.include(Usernames::Routes)
      routes = app.routes
      routes.append { Usernames::Engine.draw_availability_route(self, routes) }
    end

    # Before importmap-rails reads its paths; nothing at all without it.
    initializer "usernames.importmap", before: "importmap" do |app|
      next unless defined?(::Importmap) && app.config.respond_to?(:importmap)

      app.config.importmap.paths << root.join("config/importmap.rb")
      app.config.importmap.cache_sweepers << root.join("app/assets/javascripts")
    end

    # Propshaft and Sprockets both find an engine's app/assets on their own;
    # Sprockets also needs to be told to precompile them.
    initializer "usernames.assets" do |app|
      Usernames::Engine.add_assets(app.config.assets) if app.config.respond_to?(:assets) && app.config.assets
    end

    # After every initializer, including the app's config/initializers/usernames.rb.
    initializer "usernames.validate_configuration" do |app|
      app.config.after_initialize { Usernames.configuration.validate! }
    end

    # The app's static top-level paths are reserved — the endpoint's own
    # first segment (`usernames`) among them. They are collected lazily, on
    # the first check after the routes load; in development the routes
    # reload when config/routes.rb changes, and a page added there is
    # reserved from the next check on.
    config.after_routes_loaded { Usernames::Reserved.reset_routes! }

    class << self
      # The appended route: drawn unless the path is off or the app drew one
      # of that name itself. :nodoc:
      def draw_availability_route(mapper, routes)
        return unless Usernames.configuration.availability.path
        return if routes.named_routes.key?(:usernames_availability)

        mapper.usernames_availability
      end

      # :nodoc:
      def add_assets(assets)
        javascripts = root.join("app/assets/javascripts").to_s
        paths = assets.paths
        paths << javascripts if paths.is_a?(Array) && paths.none? { |path| path.to_s == javascripts }
        assets.precompile |= JAVASCRIPTS if assets.precompile.is_a?(Array)
      end
    end
  end
end
