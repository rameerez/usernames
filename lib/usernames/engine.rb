# frozen_string_literal: true

module Usernames
  # Not isolated, and no routes: the gem mounts nothing behind your back
  # (the availability check is a generator that copies files into the app).
  #
  # What it does do: its config/locales load BEFORE the app's — Rails puts
  # engines first and the application last — so any key in the app's own
  # locale files wins; `has_username` reaches every Active Record model; the
  # app's own routes are reserved and re-read whenever they reload; and a bad
  # configuration value fails at boot, not at the first sign-up.
  #
  # The generators (`usernames:install`, `usernames:availability`,
  # `usernames:locale`) need no wiring: Rails finds them in
  # lib/generators/usernames/ on the load path.
  class Engine < ::Rails::Engine
    initializer "usernames.active_record" do
      ActiveSupport.on_load(:active_record) { extend Usernames::Model }
    end

    # After every initializer, including the app's config/initializers/usernames.rb.
    initializer "usernames.validate_configuration" do |app|
      app.config.after_initialize { Usernames.configuration.validate! }
    end

    # The app's static top-level paths are reserved. They are
    # collected lazily, on the first check after the routes load; in
    # development the routes reload when config/routes.rb changes, and a
    # page added there is reserved from the next check on.
    config.after_routes_loaded { Usernames::Reserved.reset_routes! }
  end
end
