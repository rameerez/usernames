# frozen_string_literal: true

module Usernames
  module Generators
    # What `rails generate usernames:install` tells the developer once it has
    # written its files: the next steps on a fresh column, or the adoption
    # workflow on one that already holds usernames. :nodoc:
    module InstallMessages
      private

      def setup_message
        say "\nTo complete the setup:"
        say "  1. Run 'rails db:migrate'#{migration_summary}."
        say "  2. Add `#{macro_line}` to your #{model_name} model."
        say "\nUsernames are unique from the moment the index exists: the database decides, " \
            "with the same comparison the gem uses everywhere."
        integration_message
      end

      # On a populated column no index is a promise — not even one already in
      # place, which compares the values as they were stored (`JAVI`), while
      # the gem stores and compares them normalised (`javi`). Only the audit
      # can say the two agree.
      def adoption_message
        say "\n#{table}.#{column} already holds usernames, and `normalizes` never rewrites rows already stored, " \
            "so #{index_doubt}:", :yellow
        say "  1. Run 'rails usernames:audit[#{audit_arguments}]'. It's read-only: it lists values that differ " \
            "from their normalised form, names that would collide, and the column's collation and indexes."
        say "  2. If it finds anything, fix it in a migration you own, under a short freeze of the username form: " \
            "rewrite noncanonical values with your own callbacks and policy, and resolve collisions by contacting " \
            "the people or appending a suffix. The gem renames nobody."
        say "  3. #{nothing_to_migrate? ? 'Re-run the audit until it comes back clean' : "Run 'rails db:migrate'#{migration_summary}, re-run the audit"}, " \
            "and reopen the form."
        say "  4. Add `#{macro_line}` to your #{model_name} model. Existing names that break today's rules " \
            "keep working; only a change is validated."
        say "  See \"Adopting an existing column\" in the README."
        integration_message
      end

      # Then, in the forms: the field and its status, and the one line of
      # JavaScript behind them.
      def integration_message
        say "\nThen, in any form for a #{model_name}, a username field that checks names as people type:"
        say "  <%= f.label :#{column} %> <%= f.username_field :#{column} %> <%= f.username_status :#{column} %>"
        say "  #{JAVASCRIPT_STEPS.fetch(javascript_setup)}"
        devise_message if defined?(::Devise)
        say "  In production, the check counts requests in Rails.cache: give it a shared store (Solid Cache, " \
            "Redis, Memcached). It answers 503 until one counts."
      end

      # Devise permits only its own attributes: without these lines a sign-up
      # form says the name is free, and the save drops it.
      def devise_message
        say "  Devise drops attributes it doesn't know, so permit :#{column} where people choose or change " \
            "it (in ApplicationController, before_action ... if: :devise_controller?):"
        say "    devise_parameter_sanitizer.permit(:sign_up, keys: [:#{column}])"
        say "    devise_parameter_sanitizer.permit(:account_update, keys: [:#{column}])"
      end

      JAVASCRIPT_STEPS = {
        ready: %(Added `import "usernames"` to app/javascript/application.js.),
        imported: %(app/javascript/application.js already has `import "usernames"`.),
        no_importmap: "No importmap here: run 'rails generate usernames:javascript' to copy the Stimulus controller " \
                      "into app/javascript/controllers (then it is yours to keep up to date).",
        no_entrypoint: %(No app/javascript/application.js: add `import "usernames"` to your importmap entrypoint.),
        no_stimulus: "No app/javascript/controllers/application.js (stimulus-rails' Stimulus setup): the field " \
                     "works as a plain input; with stimulus-rails, add `import \"usernames\"` for the live check.",
        uncertain_source: "Didn't add `import \"usernames\"`: app/javascript/controllers/application.js has " \
                          "constructs the installer won't guess at (template interpolation or a regular " \
                          "expression). Add the line yourself if that file exports `application`.",
        no_application_export: "Didn't add `import \"usernames\"`: app/javascript/controllers/application.js " \
                               "doesn't export the Stimulus application by the name `application` " \
                               "(`export { application }`), which it imports, and a missing export would stop " \
                               "app/javascript/application.js loading at all. Export it under that name and add the " \
                               "line, or register \"usernames/username-check\" on your application yourself."
      }.freeze
      private_constant :JAVASCRIPT_STEPS

      def index_doubt
        return "the unique index isn't trustworthy yet (it may not even be addable)" if add_index?

        "#{matching_index.name} can't vouch for them yet: to it a stored JAVI and a new javi are two names"
      end

      def warn_about_the_database
        say "\nCouldn't reach the database to look at #{table}.#{column}, so the migration assumes the column " \
            "doesn't exist yet. If it does, delete the add_column line before migrating.", :yellow
      end

      def migration_summary
        return "" if nothing_to_migrate?

        steps = []
        steps << "to add #{table}.#{column}" if add_column?
        steps << (collation ? "to set its collation to #{collation.inspect}" : "to make it a string column") if
          change_collation?
        steps << "#{steps.empty? ? 'to add' : 'and add'} its unique index, #{index[:name]}" if add_index?
        " (#{steps.join(' ')})"
      end
    end
  end
end
