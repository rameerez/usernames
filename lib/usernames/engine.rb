# frozen_string_literal: true

module Usernames
  # Not isolated, and no routes: the gem mounts nothing behind your back
  # (the availability check is a generator that copies files into the app).
  #
  # What it does do: its config/locales load BEFORE the app's — Rails puts
  # engines first and the application last — so any key in the app's own
  # locale files wins; `has_username` reaches every Active Record model; and
  # a bad configuration value fails at boot, not at the first sign-up.
  class Engine < ::Rails::Engine
    initializer "usernames.active_record" do
      ActiveSupport.on_load(:active_record) { extend Usernames::Model }
    end

    # After every initializer, including the app's config/initializers/usernames.rb.
    initializer "usernames.validate_configuration" do |app|
      app.config.after_initialize { Usernames.configuration.validate! }
    end

    # TODO(p2): config.after_routes_loaded — collect the app's static
    # top-level paths into the reserved set (PRD §9.3).
  end
end
