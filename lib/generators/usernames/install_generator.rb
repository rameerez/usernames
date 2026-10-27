# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"
require_relative "existing_schema"
require_relative "install_messages"

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
      include InstallMessages

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
        populated? ? adoption_message : setup_message
        say "\nEnjoy your new usernames!", :green
      end

      private

      # --- what the migration does -----------------------------------------------------------------

      # A file name and a constant, whatever the table is called:
      # `public.users` makes add_username_to_public_users, AddUsernameToPublicUsers.
      def migration_name
        table_part = table.gsub(/\W+/, "_")
        column_part = column.gsub(/\W+/, "_")
        add_column? ? "add_#{column_part}_to_#{table_part}" : "add_unique_#{column_part}_index_to_#{table_part}"
      end

      def migration_class_name = migration_name.camelize

      # A table or column as the migration's argument (`:users`, `"public.users"`).
      def ruby_name(name) = Usernames::Comparison.ruby_name(name)

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
        database.indexes.find { |existing| existing.name == index[:name] && !existing.equal?(matching_index) }
      end

      def matching_index = database.matching_index

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

      # The model's own database when the model exists — an app with several
      # databases keeps its users on any of them — else the primary one.
      def connection_owner
        model_class.is_a?(Class) && model_class < ActiveRecord::Base ? model_class : ActiveRecord::Base
      end

      # From the model's database configuration, which needs no connection.
      # When even that is unknown, the migration is written for SQLite
      # (Rails' default).
      def adapter
        @adapter ||= Usernames::Comparison.adapter(connection_owner.connection_db_config&.adapter.to_s)
      rescue StandardError
        @adapter = :sqlite
      end

      def database
        @database ||= ExistingSchema.read(connection_owner, table, column, mode)
      end

      # A model on the primary database migrates where Rails always does. A
      # model on another one migrates where that database's migrations live
      # (its migrations_paths); without them there is nowhere the migration
      # would run against the right database, so the generator says so.
      def db_migrate_path
        own, primary = [connection_owner, ActiveRecord::Base].map(&:connection_db_config)
        return super if own.equal?(primary) || own.configuration_hash == primary.configuration_hash

        Array(own.migrations_paths).first || raise(Thor::Error, <<~MESSAGE.squish)
          #{model_name} lives on the #{own.name.inspect} database, which sets no migrations_paths, so a migration
          written here would run against the primary database. Add migrations_paths for it in config/database.yml
          and run the generator again.
        MESSAGE
      rescue ActiveRecord::ActiveRecordError # no database configuration to read: Rails' default
        super
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
