# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/usernames/install_generator"

# A model whose users table lives on a database of its own (see on_a_second_database).
class SecondDatabaseUser < ActiveRecord::Base
  self.table_name = "users"
end

# A model whose table is named with its schema, as PostgreSQL apps with
# several schemas name theirs.
class QualifiedPerson < ActiveRecord::Base
  self.table_name = "public.qualified_people"
end

class GeneratorInstallTest < Rails::Generators::TestCase
  tests Usernames::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator_install_test", __dir__)

  setup :prepare_destination
  setup { Member.delete_all }
  teardown { Member.delete_all }

  # The adapter as the app's database.yml names it.
  def on(adapter, &)
    ActiveRecord::Base.stub(:connection_db_config, Struct.new(:adapter).new(adapter), &)
  end

  def output_of(*args)
    run_generator(args)
  end

  # SecondDatabaseUser on an in-memory SQLite database of its own, whose
  # users table has a username column and no index on it.
  def on_a_second_database(**config)
    SecondDatabaseUser.establish_connection(adapter: "sqlite3", database: ":memory:", **config)
    SecondDatabaseUser.lease_connection.create_table(:users) { |t| t.string :username }
    yield
  ensure
    SecondDatabaseUser.remove_connection
  end

  def run_migration(source, direction)
    migration = Class.new(ActiveRecord::Migration[ActiveRecord::Migration.current_version]) do
      class_eval(source[/  def change.*^  end\n/m], __FILE__, __LINE__)
    end
    ActiveRecord::Migration.suppress_messages { migration.migrate(direction) }
  end

  # --- the initializer ------------------------------------------------------------------------------

  def test_initializer_shows_exactly_the_ten_options_commented_and_publishes_the_column
    run_generator %w[--model=Account]

    assert_file "config/initializers/usernames.rb" do |content|
      options = content.scan(/^  # (config\.[\w.]+) +\+?=/).flatten

      assert_equal %w[config.length config.separators config.edge_separators config.case config.reserved
                      config.forbidden config.allowed config.offensive.severity config.offensive.languages
                      config.offensive.allowed], options
      assert_includes content, "Usernames.configure do |config|"
      assert_equal [%(  config.availability.targets = { "account" => "Account#username" })],
                   content.lines(chomp: true).grep(/^\s+config\./),
                   "every rule is commented (the defaults stay the gem's); the one live line publishes the column"
    end
  end

  def test_the_target_names_the_model_and_column
    run_generator %w[--model=Admin::Member --column=handle]

    assert_file "config/initializers/usernames.rb",
                /config\.availability\.targets = \{ "admin_member" => "Admin::Member#handle" \}/
  end

  # --- import "usernames" ---------------------------------------------------------------------------

  # The conventional importmap + Stimulus app, as `rails new` writes it.
  def importmap_app(application_js: %(import "@hotwired/turbo-rails"\nimport "controllers"\n),
                    stimulus: "const application = Application.start()\nexport { application }\n")
    write "config/importmap.rb", %(pin "application"\n)
    write "app/javascript/application.js", application_js if application_js
    write "app/javascript/controllers/application.js", stimulus if stimulus
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(File.join(destination_root, path)))
    File.write(File.join(destination_root, path), content)
  end

  def application_js
    File.read(File.join(destination_root, "app/javascript/application.js"))
  end

  def test_appends_the_import_to_an_importmap_stimulus_app
    importmap_app
    output = run_generator %w[--model=Account]

    assert_equal %(import "@hotwired/turbo-rails"\nimport "controllers"\nimport "usernames"\n), application_js
    assert_match(%r{Added `import "usernames"` to app/javascript/application\.js}, output)
    assert_match(/<%= f\.label :username %> <%= f\.username_field :username %> <%= f\.username_status :username %>/,
                 output)
    refute_match(/devise/i, output, "no Devise here, so nothing about it")
  end

  # With Devise loaded, the two lines that keep it from dropping the field.
  def test_with_devise_the_permit_lines
    Object.const_set(:Devise, Module.new)
    output = run_generator %w[--model=Account --column=handle]

    assert_match(/Devise drops attributes it doesn't know, so permit :handle/, output)
    assert_match(/^    devise_parameter_sanitizer\.permit\(:sign_up, keys: \[:handle\]\)$/, output)
    assert_match(/^    devise_parameter_sanitizer\.permit\(:account_update, keys: \[:handle\]\)$/, output)
  ensure
    Object.send(:remove_const, :Devise) if Object.const_defined?(:Devise, false)
  end

  def test_appending_is_idempotent
    importmap_app
    run_generator %w[--model=Account]
    output = run_generator %w[--model=Account]

    assert_equal 1, application_js.scan(%(import "usernames")).size
    assert_match(/already has `import "usernames"`/, output)
  end

  def test_an_import_the_app_wrote_itself_counts
    importmap_app(application_js: %(import "controllers"\n  import 'usernames' // mine\n))
    run_generator %w[--model=Account]

    assert_equal %(import "controllers"\n  import 'usernames' // mine\n), application_js
  end

  def test_an_entrypoint_without_a_final_newline
    importmap_app(application_js: %(import "controllers"))
    run_generator %w[--model=Account]

    assert_equal %(import "controllers"\nimport "usernames"\n), application_js
  end

  # Every form that exports a binding under the name `application`.
  def test_every_named_export_of_application
    ["const application = Application.start()\nexport { application }\n",
     "export const application = Application.start()\n",
     "export let application = Application.start()\n",
     "export var application = Application.start()\n",
     "const application = Application.start()\nexport { application as application }\n",
     "const app = Application.start()\nexport { app as application }\n",
     "const application = Application.start()\nexport { other, application }\n",
     "const application = Application.start()\nexport {\n  application,\n  other\n}\n",
     "export { application } from \"./stimulus\"\n",
     "export { app as application } from \"./stimulus\"\n",
     "const application = {}; export { /* kept */ application }\n",
     "const application = {}; export { // kept\n application }\n",
     # Comments and strings read as such, not as code:
     "export/* comment */const application = {}\n",
     "const application = {}; const url = \"https://example.test\"; export { application }\n",
     "const url = 'https://example.test/*'; export const application = {}\n",
     "const a = \"say \\\"hi\\\" // not a comment\"; export { a as application }\n",
     "const t = `line one\n// still the template`; export { t as application }\n"].each do |stimulus|
      prepare_destination
      importmap_app(stimulus: stimulus)
      run_generator %w[--model=Account]

      assert_includes application_js, %(import "usernames"), stimulus
    end
  end

  # Anything else would make the bridge's `import { application }` fail to
  # link, and take the whole entrypoint with it: no line, and the reason.
  def test_no_import_without_a_named_export_of_application
    ["const application = {}\nexport { application as default }\n",
     "const application = {}\nexport { application as stimulus }\n",
     "const application = {}\nexport default application\n",
     "const application = {}\n// export { application }\n",
     "const application = {}\n/* export { application } */\n",
     "const application = {}\n/*\nexport const application = 1\n*/\n",
     "export const applicationName = \"x\"\nexport { applications }\n",
     "export function application() {}\n",
     "window.Stimulus = Application.start()\n",
     # Export text inside a string or template literal exports nothing:
     "const example = \"export { application }\"; export default {}\n",
     "const example = 'export const application = 1'; export default {}\n",
     "const example = `export { application }`; export default {}\n",
     "const example = `\nexport { application }\n`; export default {}\n"].each do |stimulus|
      prepare_destination
      importmap_app(stimulus: stimulus)
      output = run_generator %w[--model=Account]

      refute_includes application_js, "usernames", stimulus
      assert_match(/Didn't add `import "usernames"`: .* doesn't export the Stimulus application by the name /,
                   output)
    end
  end

  # What the reading doesn't follow, it doesn't guess at: template
  # interpolation and regular expressions (or division) decline the line,
  # whether or not the file really exports `application`.
  def test_no_import_where_the_source_is_uncertain
    ["const application = Application.start()\nconst t = `outer ${`inner ${\"x\"}`}`\nexport { application }\n",
     "const t = `outer ${`export { application }`}`\nexport default {}\n",
     "const application = Application.start()\nconst t = `outer ${`/*`}`\nexport { application }\n",
     "const x = /export { application }/\nexport default {}\n",
     "const application = Application.start()\nconst half = 1 / 2\nexport { application }\n"].each do |stimulus|
      prepare_destination
      importmap_app(stimulus: stimulus)
      output = run_generator %w[--model=Account]

      assert_equal :uncertain_source, generator.send(:javascript_setup), stimulus
      refute_includes application_js, "usernames", stimulus
      assert_match(/Didn't add `import "usernames"`: .* has constructs the installer won't guess at /, output)
      assert_match(/\(template interpolation or a regular expression\)\. Add the line yourself/, output)
    end
  end

  # The file stimulus-rails generates, word for word: the line goes in.
  def test_the_stimulus_rails_application_file
    importmap_app(stimulus: <<~JS)
      import { Application } from "@hotwired/stimulus"

      const application = Application.start()

      // Configure Stimulus development experience
      application.debug = false
      window.Stimulus   = application

      export { application }
    JS
    run_generator %w[--model=Account]

    assert_includes application_js, %(import "usernames")
  end

  # Only controllers/application.js is held to that: the entrypoint is read
  # for its imports, whatever else it holds.
  def test_an_entrypoint_with_templates_and_regexps_is_still_read
    importmap_app(application_js: %(import "controllers"\nconst r = /x/\nconst t = `${r}`\nimport "usernames"\n))
    output = run_generator %w[--model=Account]

    assert_match(/already has `import "usernames"`/, output)

    prepare_destination
    importmap_app(application_js: %(import "controllers"\nconst r = /x/\nconst t = `${r}`\n))
    run_generator %w[--model=Account]

    assert_equal 1, application_js.scan(%(import "usernames")).size
  end

  def test_a_commented_out_import_is_not_an_import
    importmap_app(application_js: %(import "controllers"\n// import "usernames"\n))
    run_generator %w[--model=Account]

    assert_equal %(import "controllers"\n// import "usernames"\nimport "usernames"\n), application_js
  end

  # Where the line could not work, it is not written, and the reason is said.
  def test_no_import_where_it_could_not_work
    {
      lambda {
        write "app/javascript/application.js",
              %(import "controllers"\n)
      } => /No importmap here: run 'rails generate usernames:javascript'/,
      -> { importmap_app(application_js: nil) } => %r{No app/javascript/application\.js},
      -> { importmap_app(stimulus: nil) } => %r{No app/javascript/controllers/application\.js}
    }.each do |setup, message|
      prepare_destination
      setup.call
      before = File.exist?(File.join(destination_root, "app/javascript/application.js")) && application_js
      output = run_generator %w[--model=Account]

      assert_match message, output
      assert_equal before, File.exist?(File.join(destination_root, "app/javascript/application.js")) && application_js
    end
  end

  def test_the_adoption_workflow_ends_with_the_form_too
    Member.insert_all([{ username: "javi" }])
    output = output_of("--model=Member")

    assert_match(/f\.username_field :username/, output)
  end

  # Uncommented, the initializer is a valid configuration of the defaults.
  def test_initializer_lines_are_valid_configuration
    run_generator %w[--model=Account]
    source = File.read(File.join(destination_root, "config/initializers/usernames.rb")).gsub(/^  # (config\.)/, '  \1')
    previous = Usernames.configuration

    Usernames.configuration = Usernames::Configuration.new
    eval(source) # rubocop:disable Security/Eval

    assert_equal 3..30, Usernames.configuration.length
    assert_equal %i[en es], Usernames.configuration.offensive.languages
    assert_equal({ "account" => "Account#username" }, Usernames.configuration.availability.targets)
    Usernames.configuration.validate!
  ensure
    Usernames.configuration = previous
  end

  def test_an_edited_initializer_is_never_overwritten
    run_generator %w[--model=Account]
    path = File.join(destination_root, "config/initializers/usernames.rb")
    File.write(path, "# mine\n")

    run_generator %w[--model=Account]

    assert_equal "# mine\n", File.read(path)
  end

  # --- a new column ---------------------------------------------------------------------------------

  def test_adds_the_column_and_a_plain_unique_index_in_lowercase_mode
    output = on("sqlite3") { output_of("--model=Account") }

    assert_migration "db/migrate/add_username_to_accounts.rb" do |content|
      assert_match(/class AddUsernameToAccounts < ActiveRecord::Migration\[\d+\.\d+\]/, content)
      assert_includes content, "add_column :accounts, :username, :string\n"
      assert_includes content, %(add_index :accounts, :username, unique: true, name: "index_accounts_on_username")
    end
    assert_match(/rails db:migrate' \(to add accounts.username and add its unique index, index_accounts_on_username\)/,
                 output)
    assert_match(/Add `has_username` to your Account model/, output)
    refute_match(/already holds usernames/, output)
  end

  def test_preserve_mode_writes_the_expression_index
    on("sqlite3") { run_generator %w[--model=Account --case=preserve] }

    assert_migration "db/migrate/add_username_to_accounts.rb" do |content|
      assert_includes content,
                      %(add_index :accounts, "lower(username)", unique: true, name: "index_accounts_on_lower_username")
      assert_includes content, "CoolCat and coolcat are"
    end
  end

  def test_postgresql_gets_the_c_collation_in_lowercase_mode
    on("postgresql") { run_generator %w[--model=Account] }

    assert_migration "db/migrate/add_username_to_accounts.rb" do |content|
      assert_includes content, %(add_column :accounts, :username, :string, collation: "C")
      assert_includes content, %(add_index :accounts, :username, unique: true)
    end
  end

  # The expression carries COLLATE "C", so the column keeps the database's
  # collation: a "C" column would sort every capitalised name first in an
  # ORDER BY — exactly what keeping typed case makes visible.
  def test_postgresql_preserve_mode_leaves_the_column_collation_alone
    output = on("postgresql") { output_of("--model=Account", "--case=preserve") }

    assert_migration "db/migrate/add_username_to_accounts.rb" do |content|
      assert_includes content, "add_column :accounts, :username, :string\n"
      refute_includes content, "collation:"
      assert_includes content, %(add_index :accounts, 'lower(username COLLATE "C")', unique: true)
    end
    refute_match(/set its collation/, output)
  end

  def test_mysql_gets_utf8mb4_bin
    on("trilogy") { run_generator %w[--model=Account --column=handle] }

    assert_migration "db/migrate/add_handle_to_accounts.rb" do |content|
      assert_includes content, %(add_column :accounts, :handle, :string, collation: "utf8mb4_bin")
      assert_includes content, %(add_index :accounts, :handle, unique: true, name: "index_accounts_on_handle")
    end
  end

  def test_the_case_mode_comes_from_the_models_has_username
    output = output_of("--model=Player", "--column=handle")

    assert_match(/players.handle and index_players_on_lower_handle are already in place/, output)
    refute_match(/rails db:migrate' \(/, output)
  end

  def test_a_bad_case_mode_is_refused
    output = capture(:stderr) { run_generator %w[--model=Account --case=upper] }

    assert_match(/--case must be lowercase or preserve/, output)
  end

  # --- an existing column -------------------------------------------------------------------------

  def test_an_empty_existing_column_gets_only_its_index
    output = output_of("--model=Member")

    assert_no_migration "db/migrate/add_username_to_members.rb"
    assert_migration "db/migrate/add_unique_username_index_to_members.rb" do |content|
      refute_includes content, "add_column"
      assert_includes content, %(add_index :members, :username, unique: true, name: "index_members_on_username")
    end
    refute_match(/already holds usernames/, output)
  end

  def test_a_populated_column_prints_the_adoption_workflow_instead_of_claiming_uniqueness
    Member.lease_connection.execute("INSERT INTO members (username) VALUES ('JAVI')")

    output = output_of("--model=Member")

    assert_match(/members.username already holds usernames/, output)
    assert_match(/rails usernames:audit\[Member,username\]'/, output)
    assert_match(/under a short freeze of the username form/, output)
    assert_match(/The gem renames nobody/, output)
    refute_match(/Usernames are unique from the moment/, output)
    assert_migration "db/migrate/add_unique_username_index_to_members.rb"
  end

  # An index already in place compares what is stored: a raw JAVI and a new
  # javi are two names to it. So a populated column always gets the audit.
  def test_a_populated_column_with_its_index_in_place_still_gets_the_adoption_workflow
    User.delete_all
    User.lease_connection.execute("INSERT INTO users (username, email) VALUES ('JAVI', 'adopted@example.com')")

    output = output_of("--model=User")

    assert_match(/users.username already holds usernames/, output)
    assert_match(/index_users_on_username can't vouch for them yet/, output)
    assert_match(/rails usernames:audit\[User,username\]'/, output)
    assert_match(/3\. Re-run the audit until it comes back clean, and reopen the form/, output)
    refute_match(/Usernames are unique from the moment/, output)
    refute_match(/rails db:migrate/, output, "there is nothing to migrate")
  ensure
    User.delete_all
  end

  # The audit runs before has_username is declared, so it is told the mode.
  def test_the_adoption_workflow_passes_a_preserve_mode_to_the_audit
    Member.lease_connection.execute("INSERT INTO members (handle) VALUES ('Javi')")

    output = output_of("--model=Member", "--column=handle", "--case=preserve")

    assert_match(/rails usernames:audit\[Member,handle,preserve\]'/, output)
  end

  def test_a_finished_install_writes_no_migration
    output = output_of("--model=User")

    assert_match(/users.username and index_users_on_username are already in place/, output)
    assert_no_migration "db/migrate/add_unique_username_index_to_users.rb"
    assert_no_migration "db/migrate/add_username_to_users.rb"
  end

  def test_a_postgresql_column_is_adopted_with_the_c_collation
    output = on("postgresql") { output_of("--model=Member") }

    assert_migration "db/migrate/add_unique_username_index_to_members.rb" do |content|
      assert_includes content, %(direction.up { change_column :members, :username, :string, collation: "C" })
      assert_includes content, %(add_index :members, :username, unique: true)
    end
    assert_match(/to set its collation to "C"/, output)
  end

  def test_a_postgresql_column_adopted_in_preserve_mode_keeps_its_collation
    output = on("postgresql") { output_of("--model=Member", "--case=preserve") }

    assert_migration "db/migrate/add_unique_username_index_to_members.rb" do |content|
      refute_includes content, "change_column"
      assert_includes content, %(add_index :members, 'lower(username COLLATE "C")', unique: true)
    end
    refute_match(/collation/, output)
  end

  # citext still becomes a plain string, with no collation of its own.
  def test_a_citext_column_adopted_in_preserve_mode_becomes_a_plain_string
    citext = Struct.new(:name, :sql_type, :collation).new("username", "citext", nil)
    schema = Usernames::Generators::ExistingSchema.new(reachable: true, column: citext)
    output = Usernames::Generators::ExistingSchema.stub(:read, schema) do
      on("postgresql") { output_of("--model=Member", "--case=preserve") }
    end

    assert_migration "db/migrate/add_unique_username_index_to_members.rb" do |content|
      assert_includes content, "direction.up { change_column :members, :username, :string }"
      assert_includes content, "citext compares under the database locale"
    end
    assert_match(/to make it a string column and add its unique index/, output)
  end

  def test_a_mysql_column_is_shown_the_collation_line
    on("mysql2") { run_generator %w[--model=Member] }

    assert_migration "db/migrate/add_unique_username_index_to_members.rb" do |content|
      assert_includes content, %(# change_column :members, :username, :string, collation: "utf8mb4_bin")
    end
  end

  def test_an_index_of_the_same_name_that_is_not_unique_is_replaced
    Member.lease_connection.add_index :members, :username, name: "index_members_on_username"

    run_generator %w[--model=Member]

    assert_migration "db/migrate/add_unique_username_index_to_members.rb" do |content|
      assert_includes content, %(remove_index :members, column: [:username], name: "index_members_on_username")
      assert_includes content, %(add_index :members, :username, unique: true, name: "index_members_on_username")
    end
  ensure
    Member.lease_connection.remove_index :members, name: "index_members_on_username", if_exists: true
  end

  # A host app's own lower() index under the gem's name: replaced by one that
  # can be rolled back, because the remove line restates the expression.
  def test_an_expression_index_of_the_same_name_is_replaced_reversibly
    connection = Member.lease_connection
    connection.add_index :members, "lower(username)", name: "index_members_on_lower_username"

    run_generator %w[--model=Member --case=preserve]

    assert_migration "db/migrate/add_unique_username_index_to_members.rb" do |content|
      assert_match(/def change\n    # index_members_on_lower_username isn't/, content, "no blank line opens the method")
      # As the database reads the expression back: PostgreSQL says lower((username)::text).
      assert_match(/remove_index :members, "lower\(.*username.*\)", name: "index_members_on_lower_username"\n/, content)
      assert_includes content, "lower_username\"\n\n    # Case is kept"
      run_migration(content, :up)

      assert connection.indexes(:members).find { |index| index.name == "index_members_on_lower_username" }.unique
      run_migration(content, :down)

      refute connection.indexes(:members).find { |index| index.name == "index_members_on_lower_username" }.unique
    end
  ensure
    Member.lease_connection.remove_index :members, name: "index_members_on_lower_username", if_exists: true
  end

  # A partial unique index lets two inactive accounts share a name, so it is
  # not the index the gem needs: the migration still adds that one.
  def test_a_partial_unique_index_does_not_count_as_in_place
    connection = Member.lease_connection
    connection.add_index :members, :username, unique: true, where: "email IS NOT NULL", name: "members_partial"

    output = run_generator %w[--model=Member]

    assert_migration "db/migrate/add_unique_username_index_to_members.rb",
                     /add_index :members, :username, unique: true, name: "index_members_on_username"/
    assert_match(/ignore  members_partial doesn't make username unique: it only covers rows WHERE \(?email IS NOT NULL/,
                 output)
  ensure
    connection.remove_index :members, name: "members_partial", if_exists: true
  end

  # The migration, run against this database: afterwards the index the
  # audit, the installer and the race wrapper look for is there, in both
  # modes; rolled back, it is gone.
  def test_the_migration_creates_the_index_the_contract_needs
    connection = Member.lease_connection
    %i[lowercase preserve].each do |mode|
      prepare_destination
      run_generator ["--model=Member", "--case=#{mode}"]
      contract = Usernames::Comparison::IndexContract.new(connection, table: :members, column: :username, mode: mode)
      enforced = -> { connection.indexes(:members).any? { |index| contract.satisfied_by?(index) } }

      assert_migration "db/migrate/add_unique_username_index_to_members.rb" do |content|
        refute enforced.call, "#{mode}: not before"
        run_migration(content, :up)

        assert enforced.call, "#{mode}: after db:migrate"
        run_migration(content, :down)

        refute enforced.call, "#{mode}: rolled back"
      end
      connection.change_column(:members, :username, :string) if POSTGRESQL # the collation the up step set
    end
  end

  # --- a schema-qualified table -----------------------------------------------------------------------

  # The constant is built from the name, the table stays a string literal:
  # `:public.users` is not Ruby. On PostgreSQL the migration runs both ways.
  def test_a_schema_qualified_table_gets_a_migration_that_parses_and_runs
    connection = ActiveRecord::Base.lease_connection
    connection.create_table(:qualified_people, force: true) if POSTGRESQL
    run_generator %w[--model=QualifiedPerson]

    assert_migration "db/migrate/add_username_to_public_qualified_people.rb" do |content|
      assert_match(/^class AddUsernameToPublicQualifiedPeople < ActiveRecord::Migration\[/, content)
      assert_match(/add_column "public.qualified_people", :username, :string(, collation: "C")?\n/, content)
      assert_includes content, %(add_index "public.qualified_people", :username, unique: true, ) +
                               %(name: "index_qualified_people_on_username")
      assert RubyVM::InstructionSequence.compile(content)
      next unless POSTGRESQL

      run_migration(content, :up)

      assert connection.column_exists?(:qualified_people, :username)
      run_migration(content, :down)

      refute connection.column_exists?(:qualified_people, :username)
    end
  ensure
    connection.drop_table(:qualified_people, if_exists: true)
  end

  # --- a model on another database -------------------------------------------------------------------

  # Its own database, read through its own connection: the primary one's
  # users.username index says nothing about this table.
  def test_a_model_on_another_database_is_read_and_migrated_there
    on_a_second_database(migrations_paths: "db/second_migrate") do
      output = output_of("--model=SecondDatabaseUser", "--case=preserve")

      assert_migration "db/second_migrate/add_unique_username_index_to_users.rb" do |content|
        assert_includes content, %(add_index :users, "lower(username)", unique: true), "SQLite's expression"
      end
      assert_no_migration "db/migrate/add_unique_username_index_to_users.rb"
      refute_match(/already in place/, output)
    end
  end

  def test_a_model_on_another_database_without_migrations_paths_is_refused
    on_a_second_database do
      error = capture(:stderr) { run_generator %w[--model=SecondDatabaseUser] }

      assert_match(/SecondDatabaseUser lives on the "primary" database, which sets no migrations_paths/, error)
      assert_no_migration "db/migrate/add_unique_username_index_to_users.rb"
    end
  end

  def test_a_unique_index_is_removed_with_its_uniqueness_and_condition
    index = ActiveRecord::ConnectionAdapters::IndexDefinition.new(
      "members", "index_members_on_username", true, %w[username], where: "username IS NOT NULL"
    )
    line = Usernames::Generators::ExistingSchema.remove_index_line("members", index)

    assert_equal %(remove_index :members, column: [:username], unique: true, where: "username IS NOT NULL", ) +
                 %(name: "index_members_on_username"), line
  end

  # --- no database, and re-runs ---------------------------------------------------------------------

  def test_runs_without_a_database
    output = ActiveRecord::Base.stub(:with_connection, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
      output_of("--model=User")
    end

    assert_match(/Couldn't reach the database/, output)
    assert_migration "db/migrate/add_username_to_users.rb"
  end

  # The index and the collation depend on the adapter: one the gem has no
  # comparison contract for, or none at all, writes no migration.
  def test_an_unknown_adapter_is_refused
    error = on("oracle_enhanced") { capture(:stderr) { run_generator %w[--model=Account] } }

    assert_match(/supports PostgreSQL, MySQL and SQLite; the "oracle_enhanced" adapter/, error)
    assert_no_migration "db/migrate/add_username_to_accounts.rb"
  end

  def test_an_unreadable_adapter_is_refused
    error = ActiveRecord::Base.stub(:connection_db_config, -> { raise ActiveRecord::AdapterNotSpecified }) do
      capture(:stderr) { run_generator %w[--model=Account] }
    end

    assert_match(/couldn't read Account's database adapter/, error)
    assert_no_migration "db/migrate/add_username_to_accounts.rb"
  end

  def test_re_running_is_idempotent
    run_generator %w[--model=Account]
    output = output_of("--model=Account")

    assert_match(%r{identical\s+db/migrate/\d+_add_username_to_accounts.rb}, output)
    assert_match(%r{(identical|skip)\s+config/initializers/usernames.rb}, output)
    assert_equal 1, Dir[File.join(destination_root, "db/migrate/*.rb")].size
  end

  def test_names_the_column_in_the_has_username_line
    assert_match(/Add `has_username :handle` to your Account model/, output_of("--model=Account", "--column=handle"))
    assert_match(/Add `has_username case: :preserve` to your Account model/,
                 output_of("--model=Account", "--case=preserve"))
  end

  def test_generator_class
    assert Usernames::Generators::InstallGenerator.source_root.end_with?("lib/generators/usernames/templates")
    assert_includes Usernames::Generators::InstallGenerator.included_modules, ActiveRecord::Generators::Migration
  end
end
