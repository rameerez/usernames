# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"
require_relative "existing_schema"

module Usernames
  module Generators
    # rails generate usernames:install [--model=User] [--column=username] [--case=preserve]
    #
    # Writes config/initializers/usernames.rb and one migration: the column
    # (if the table has none), byte-compared ("C" on PostgreSQL, utf8mb4_bin
    # on MySQL — except PostgreSQL in preserve mode, whose index expression
    # carries the "C" itself), and the ONE unique index the gem needs, built
    # from the same expression every query uses (Usernames::Comparison).
    #
    # It looks at the database first, when it can reach it, so a re-run
    # writes nothing twice and an existing column is adopted rather than
    # added. A column that already holds usernames gets the adoption workflow
    # instead of a promise: the index cannot be trusted — or even added —
    # until `rails usernames:audit` comes back clean.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Add usernames to a model: the initializer, the column if missing, and its unique index."

      class_option :model, type: :string, default: "User", desc: "The model that gets has_username"
      class_option :column, type: :string, default: "username", desc: "The column that holds the username"
      # NOTE(p3): PRD §16 lists --model and --column only. The index depends
      # on the case mode, so the generator reads it from the model's
      # has_username (or config.case) and --case overrides that.
      class_option :case, type: :string,
                          desc: "lowercase or preserve (default: the model's has_username, else config.case)"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_initializer
        # Never over an initializer the app has already edited.
        template "usernames.rb", "config/initializers/usernames.rb", skip: true
      end

      def create_migration_file
        if nothing_to_migrate?
          say_status :skip, "#{table}.#{column} and #{matching_index.name} are already in place", :yellow
          return
        end

        migration_template "add_username.rb.erb", File.join(db_migrate_path, "#{migration_name}.rb")
      end

      def display_post_install_message
        say "\n\tThe `usernames` gem has been successfully installed!", :green
        warn_about_the_database unless database.reachable?
        populated? && add_index? ? adoption_message : setup_message
        say "\nEnjoy your new usernames!", :green
      end

      private

      def setup_message
        say "\nTo complete the setup:"
        say "  1. Run 'rails db:migrate'#{migration_summary}."
        say "  2. Add `#{macro_line}` to your #{model_name} model."
        say "  3. Optionally, run 'rails generate usernames:availability' for a live \"is this name free?\" " \
            "check on your sign-up form."
        say "\nUsernames are unique from the moment the index exists: the database decides, " \
            "with the same comparison the gem uses everywhere."
      end

      # PRD §11.5: on a populated column the unique index is a promise only
      # the audit can make.
      def adoption_message
        say "\n#{table}.#{column} already holds usernames, and `normalizes` never rewrites rows already stored, " \
            "so the unique index isn't trustworthy yet (it may not even be addable):", :yellow
        say "  1. Run 'rails usernames:audit[#{audit_arguments}]'. It's read-only: it lists values that differ " \
            "from their normalised form, names that would collide, and the column's collation and indexes."
        say "  2. If it finds anything, fix it in a migration you own, under a short freeze of the username form: " \
            "rewrite noncanonical values with your own callbacks and policy, and resolve collisions by contacting " \
            "the people or appending a suffix. The gem renames nobody."
        say "  3. Run 'rails db:migrate'#{migration_summary}, re-run the audit, and reopen the form."
        say "  4. Add `#{macro_line}` to your #{model_name} model. Existing names that break today's rules " \
            "keep working; only a change is validated."
        say "  See \"Adopting an existing column\" in the README."
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

      # --- what the migration does -----------------------------------------------------------------

      def migration_name
        add_column? ? "add_#{column}_to_#{table}" : "add_unique_#{column}_index_to_#{table}"
      end

      def migration_class_name = migration_name.camelize

      def nothing_to_migrate?
        !add_column? && !change_collation? && !add_index?
      end

      def add_column? = database.column.nil?

      # Adopting a PostgreSQL column: set "C" when it is anything else, and
      # make citext a plain string (D-17). In preserve mode the comparison
      # carries its own COLLATE "C", so only citext changes: the column keeps
      # the collation its ORDER BY sorts by. MySQL's change_column restates
      # the whole column definition, so there the migration only shows the line.
      def change_collation?
        existing = database.column
        return false if existing.nil? || adapter != :postgresql

        existing.sql_type == "citext" || (!collation.nil? && existing.collation != collation)
      end

      def mysql_collation_note?
        existing = database.column
        !existing.nil? && adapter == :mysql && existing.collation != collation
      end

      def add_index? = matching_index.nil?

      # An index of the same name that is not the one the mode needs (a plain
      # non-unique index_users_on_username, say) has to go first.
      def conflicting_index
        database.indexes.find { |existing| existing.name == index[:name] && !Usernames::Comparison.index_matches?(existing, index) }
      end

      def matching_index
        database.indexes.find { |existing| Usernames::Comparison.index_matches?(existing, index) }
      end

      # Whether the migration touches the column before its indexes.
      def column_step? = add_column? || change_collation? || mysql_collation_note?

      def index
        @index ||= Usernames::Comparison.index_definition(adapter: adapter, table: table, column: column, mode: mode)
      end

      def collation = Usernames::Comparison.column_collation(adapter, mode)

      # As the PRD writes it: 'lower(username COLLATE "C")', not an escaped string.
      def index_column
        wanted = index[:column]
        return wanted.inspect unless wanted.is_a?(String) && wanted.include?('"') && !wanted.include?("'")

        "'#{wanted}'"
      end

      def column_options = collation ? ", collation: #{collation.inspect}" : ""

      # The audit runs before has_username is declared, so it is told a mode
      # the configuration does not already say.
      def audit_arguments = [model_name, column, (mode if mode != configured_mode)].compact.join(",")

      def macro_line
        options = []
        options << ":#{column}" unless column == "username"
        options << "case: :preserve" if mode == :preserve && configured_mode != :preserve
        ["has_username", options.join(", ")].reject(&:empty?).join(" ")
      end

      # --- the app ---------------------------------------------------------------------------------

      def model_name
        options[:model].camelize
      end

      def model_class
        model_name.safe_constantize
      rescue StandardError, LoadError
        nil
      end

      def table
        @table ||= model_class.try(:table_name) || model_name.tableize.tr("/", "_")
      end

      def column
        options[:column].to_s
      end

      def mode
        @mode ||= begin
          given = options[:case]&.to_sym || declared_mode || configured_mode
          unless %i[lowercase preserve].include?(given)
            raise Thor::Error, "--case must be lowercase or preserve (got #{options[:case].inspect})"
          end

          given
        end
      end

      def declared_mode
        model_class.try(:_usernames)&.[](column.to_sym)&.mode
      end

      def configured_mode
        Usernames.configuration.case
      end

      # From the app's database configuration, which needs no connection.
      # NOTE(p3): when even that is unknown, the migration is written for
      # SQLite (Rails' default) and the message says so.
      def adapter
        @adapter ||= Usernames::Comparison.adapter(ActiveRecord::Base.connection_db_config&.adapter.to_s)
      rescue StandardError
        @adapter = :sqlite
      end

      def database
        @database ||= ExistingSchema.read(table, column)
      end

      def populated?
        database.populated?
      end

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
