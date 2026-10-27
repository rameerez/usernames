# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < UsernamesTestCase
  def config
    Usernames.configuration
  end

  def assert_invalid(pattern, &)
    error = assert_raises(Usernames::ConfigurationError, &)

    assert_match pattern, error.message
  end

  # ---- Defaults: the ten initializer options, then the README-only ones --------

  def test_the_initializer_defaults
    assert_equal 3..30, config.length
    assert_equal %w[_], config.separators
    refute config.edge_separators
    assert_equal :lowercase, config.case
    assert_equal :strong, config.offensive.severity
    assert_equal %i[en es], config.offensive.languages
    assert_empty config.offensive.allowed
    assert_empty config.allowed
  end

  def test_the_documented_less_common_defaults
    assert_equal :alphanumeric, config.first_character
    assert config.reserve_routes
    assert_nil config.app_name
    assert_equal [:moderate], config.offensive.adapters
    assert_equal :allow, config.on_adapter_failure
    assert_nil config.generator.callable
    assert_nil config.unique_index
  end

  def test_word_lists_start_from_the_bundled_data
    assert_equal Usernames::Data.reserved, config.reserved
    assert_equal Usernames::Data.impersonation, config.forbidden
    assert_equal Usernames::Data.adjectives, config.generator.adjectives
    assert_equal Usernames::Data.nouns, config.generator.nouns
  end

  def test_the_default_configuration_is_valid
    assert_same config, config.validate!
  end

  def test_configuration_is_created_lazily_and_kept
    Usernames.configuration = nil

    assert_instance_of Usernames::Configuration, Usernames.configuration
    assert_same Usernames.configuration, Usernames.configuration
  end

  # ---- configure -------------------------------------------------------------------

  def test_configure_yields_the_configuration
    Usernames.configure do |c|
      c.length = 2..24
      c.separators = %w[_ .]
      c.offensive.severity = :severe
    end

    assert_equal 2..24, config.length
    assert_equal %w[_ .], config.separators
    assert_equal :severe, config.offensive.severity
  end

  def test_configure_validates_at_the_end_of_the_block
    assert_invalid(/case must be one of :lowercase, :preserve \(got :lower\)/) do
      Usernames.configure { |c| c.case = :lower }
    end
  end

  # ---- += adds, = replaces ------------------------------------------------------------

  def test_plus_equals_adds_to_the_bundled_lists
    Usernames.configure do |c|
      c.reserved += %w[recipe recipes]
      c.forbidden += %w[yourapp yourap]
      c.allowed += %w[nick page]
      c.offensive.allowed += %w[sussex]
    end

    assert_equal Usernames::Data.reserved + %w[recipe recipes], config.reserved
    assert_equal Usernames::Data.impersonation + %w[yourapp yourap], config.forbidden
    assert_equal %w[nick page], config.allowed
    assert_equal %w[sussex], config.offensive.allowed
  end

  def test_equals_replaces_them
    config.reserved = %w[recipe]
    config.forbidden = []

    assert_equal %w[recipe], config.reserved
    assert_empty config.forbidden
  end

  def test_lists_are_frozen_so_an_in_place_change_cannot_go_unnoticed
    assert_raises(FrozenError) { config.reserved << "x" }
    assert_raises(FrozenError) { config.separators << "." }
    assert_raises(FrozenError) { config.offensive.languages << :pt }
    assert_raises(FrozenError) { config.generator.nouns << "otter" }
  end

  def test_assigning_a_list_does_not_freeze_the_callers_array
    mine = %w[recipe]
    config.reserved = mine
    mine << "other"

    assert_equal %w[recipe], config.reserved
  end

  # ---- The generator --------------------------------------------------------------------

  def test_generator_accepts_a_callable
    shape = ->(attempt) { "player#{attempt}" }
    config.generator = shape

    assert_same shape, config.generator.callable
    assert_same shape, config.rules_for.generator.callable
  end

  def test_generator_word_lists
    config.generator.adjectives = %w[swift silent]
    config.generator.nouns = %w[comet pulsar]

    assert_equal %w[swift silent], config.rules_for.generator.adjectives
    assert_equal %w[comet pulsar], config.rules_for.generator.nouns
  end

  def test_generator_must_be_callable
    config.generator = "quiet_otter"

    assert_invalid(/generator must be a callable/) { config.validate! }
  end

  # ---- Every bad value is named ------------------------------------------------------------

  def test_bad_lengths
    [3, "3..30", 0..30, 5..3, 3...3, (3..), (..30), 1.5..3, 3..Float::INFINITY].each do |bad|
      config.length = bad

      assert_invalid(/length must be a Range of whole numbers from 1 up, like 3..30 \(got #{Regexp.escape(bad.inspect)}\)/) do
        config.validate!
      end
    end
  end

  def test_bad_separators
    [%w[+], "_", [:_], %w[_ +], nil].each do |bad|
      config.separators = bad

      assert_invalid(/separators must be a list drawn from "_", "." and|separators must be a list drawn from/) do
        config.validate!
      end
    end
  end

  def test_repeated_separators_are_kept_once
    config.separators = %w[_ _ .]

    assert_equal %w[_ .], config.rules_for.separators
  end

  def test_bad_booleans
    %i[edge_separators reserve_routes].each do |name|
      reset_configuration!
      config.public_send(:"#{name}=", "true")

      assert_invalid(/#{name} must be one of true, false \(got "true"\)/) { config.validate! }
    end
  end

  def test_bad_choices
    { case: :upper, first_character: :digit, on_adapter_failure: :ignore }.each do |name, bad|
      reset_configuration!
      config.public_send(:"#{name}=", bad)

      assert_invalid(/#{name} must be one of .* \(got #{bad.inspect}\)/) { config.validate! }
    end
  end

  def test_bad_word_lists_name_the_bad_entry
    %i[reserved forbidden allowed].each do |name|
      reset_configuration!
      config.public_send(:"#{name}=", ["fine", 42])

      assert_invalid(/#{name} must be a list of words, like %w\[recipe\] \(got 42 in it\)/) { config.validate! }
    end

    config.allowed = ["fine", "  "]

    assert_invalid(/got "  " in it/) { config.validate! }
  end

  def test_a_word_list_that_is_not_a_list
    config.reserved = "recipe"

    assert_invalid(/reserved must be a list of words, like %w\[recipe\] \(got "recipe"\)/) { config.validate! }
  end

  def test_bad_offensive_settings
    config.offensive.severity = :nuclear

    assert_invalid(/offensive.severity must be one of :severe, :strong, :mild, :off \(got :nuclear\)/) do
      config.validate!
    end

    reset_configuration!
    config.offensive.languages = %w[en]

    assert_invalid(/offensive.languages must be a list of locale symbols/) { config.validate! }

    reset_configuration!
    config.offensive.languages = %i[english]

    assert_invalid(/offensive.languages has no word list for :english \(available: :en, :es\)/) { config.validate! }

    reset_configuration!
    config.offensive.languages = %i[en sp]

    assert_invalid(/no word list for :sp/) { config.validate! }

    reset_configuration!
    config.offensive.allowed = [nil]

    assert_invalid(/offensive.allowed must be a list of words/) { config.validate! }

    reset_configuration!
    config.offensive.adapters = [:obscenity]

    assert_invalid(/offensive.adapters must be a list of :moderate or callables, like \[:moderate\] \(got \[:obs/) do
      config.validate!
    end
  end

  def test_every_severity_and_adapter_kind_is_accepted
    %i[severe strong mild off].each do |severity|
      config.offensive.severity = severity

      assert config.validate!
    end
    config.offensive.adapters = [:moderate, ->(_name) { false }]
    config.offensive.languages = %i[es en]

    assert config.validate!
  end

  def test_bad_generator_word_lists
    config.generator.adjectives = [""]

    assert_invalid(/generator.adjectives must be a list of words/) { config.validate! }
  end

  def test_app_name
    ["Acme", false, nil].each do |good|
      config.app_name = good

      assert config.validate!
    end

    ["", "  ", true, :acme].each do |bad|
      config.app_name = bad

      assert_invalid(/app_name must be a String, false to opt out, or nil to detect it/) { config.validate! }
    end
  end

  def test_unique_index
    ["index_users_on_username", :index_users_on_username, nil].each do |good|
      config.unique_index = good

      assert config.validate!
    end

    ["", 42].each do |bad|
      config.unique_index = bad

      assert_invalid(/unique_index must be the name of an index, or nil/) { config.validate! }
    end
  end

  # ---- rules_for: per-call options merged over the configuration ---------------------------

  def test_rules_for_without_options_is_the_configuration
    rules = config.rules_for

    assert_equal 3..30, rules.length
    assert_equal %w[_], rules.separators
    assert_equal :lowercase, rules.case
    assert_predicate rules, :frozen?
  end

  def test_scalar_options_replace_the_configured_value
    rules = config.rules_for(length: 2..24, case: :preserve, separators: %w[_ . -], edge_separators: true,
                             first_character: :letter, on_adapter_failure: :reject, reserve_routes: false,
                             app_name: false, unique_index: "index_players_on_lower_handle")

    assert_equal 2..24, rules.length
    assert_equal :preserve, rules.case
    assert_equal %w[_ . -], rules.separators
    assert rules.edge_separators
    assert_equal :letter, rules.first_character
    assert_equal :reject, rules.on_adapter_failure
    refute rules.reserve_routes
    refute rules.app_name
    assert_equal "index_players_on_lower_handle", rules.unique_index
  end

  def test_list_options_add_to_the_configured_lists
    config.allowed = %w[nick]
    rules = config.rules_for(reserved: %w[recipe], forbidden: %w[yourapp], allowed: %w[page])

    assert_equal Usernames::Data.reserved + %w[recipe], rules.reserved
    assert_equal Usernames::Data.impersonation + %w[yourapp], rules.forbidden
    assert_equal %w[nick page], rules.allowed
  end

  def test_offensive_options_merge_with_allowed_added
    config.offensive.allowed = %w[sussex]
    rules = config.rules_for(offensive: { severity: :severe, languages: %i[es], allowed: %w[cockburn] })

    assert_equal :severe, rules.offensive.severity
    assert_equal %i[es], rules.offensive.languages
    assert_equal %w[sussex cockburn], rules.offensive.allowed
    assert_equal [:moderate], rules.offensive.adapters
  end

  def test_generator_options
    shape = ->(attempt) { "p#{attempt}" }

    assert_same shape, config.rules_for(generator: shape).generator.callable
    assert_equal %w[comet], config.rules_for(generator: { nouns: %w[comet] }).generator.nouns
    assert_nil config.rules_for(generator: nil).generator.callable
  end

  def test_bad_per_call_options
    assert_invalid(/unknown option :lenght \(known: length, separators/) { config.rules_for(lenght: 2..15) }
    assert_invalid(/length must be a Range/) { config.rules_for(length: 2) }
    assert_invalid(/reserved must be a list of words, like %w\[recipe\] \(got "x"\)/) do
      config.rules_for(reserved: "x")
    end
    assert_invalid(/offensive must be a Hash of severity, languages, allowed, adapters \(got :off\)/) do
      config.rules_for(offensive: :off)
    end
    assert_invalid(/unknown option offensive.level/) { config.rules_for(offensive: { level: :off }) }
    assert_invalid(/generator must be a Hash of adjectives, nouns, callable \(got "x"\)/) do
      config.rules_for(generator: "x")
    end
    assert_invalid(/unknown option generator.verbs/) { config.rules_for(generator: { verbs: [] }) }
  end

  def test_per_call_options_leave_the_configuration_alone
    config.rules_for(length: 2..15, reserved: %w[recipe])

    assert_equal 3..30, config.length
    assert_equal Usernames::Data.reserved, config.reserved
  end

  # ---- The compiled-rules cache -------------------------------------------------------------

  def test_rules_are_compiled_once_per_option_set
    assert_same config.rules_for, config.rules_for
    assert_same config.rules_for(length: 2..15), config.rules_for(length: 2..15)
    refute_same config.rules_for, config.rules_for(length: 2..15)
  end

  def test_every_writer_invalidates_the_cache
    writers = {
      length: 2..15, separators: %w[_ .], edge_separators: true, case: :preserve, first_character: :letter,
      reserve_routes: false, app_name: "Acme", reserved: %w[x], forbidden: %w[y], allowed: %w[z],
      on_adapter_failure: :reject, unique_index: "i", generator: ->(_) { "x" }
    }

    writers.each do |name, value|
      before = config.rules_for
      config.public_send(:"#{name}=", value)

      refute_same before, config.rules_for, "#{name}= kept stale rules"
    end
  end

  def test_nested_writers_invalidate_the_cache_too
    { severity: :severe, languages: %i[en], allowed: %w[x], adapters: [] }.each do |name, value|
      before = config.rules_for
      config.offensive.public_send(:"#{name}=", value)

      refute_same before, config.rules_for, "offensive.#{name}= kept stale rules"
    end

    { adjectives: %w[a], nouns: %w[b], callable: nil }.each do |name, value|
      before = config.rules_for
      config.generator.public_send(:"#{name}=", value)

      refute_same before, config.rules_for, "generator.#{name}= kept stale rules"
    end
  end

  def test_a_changed_configuration_changes_the_answers
    refute Usernames.allowed?("jd")
    config.length = 2..30

    assert Usernames.allowed?("jd")
  end

  def test_the_cache_is_bounded
    100.times { |index| config.rules_for(length: 3..(30 + index)) }

    assert_operator config.instance_variable_get(:@rules_cache).size, :<=, Usernames::Configuration::CACHE_LIMIT
  end

  # ---- Rules value -----------------------------------------------------------------------------

  def test_rules_inspect_is_short
    inspect = config.rules_for.inspect

    assert_equal "#<Usernames::Rules length=3..30 separators=[\"_\"] case=:lowercase edge_separators=false " \
                 "first_character=:alphanumeric offensive.severity=:strong>", inspect
  end

  def test_to_h_lists_every_option
    assert_equal Usernames::Rules::Options::NAMES.sort, config.to_h.keys.sort
  end

  # ---- Bundled data loading -----------------------------------------------------------------------

  def test_data_lists_skip_comments_and_blank_lines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "list.txt")
      File.write(path, "# source: somewhere\n\nadmin\n  root  # a reason\n#only a comment\n")

      assert_equal %w[admin root], Usernames::Data.list(path)
      assert_predicate Usernames::Data.list(path), :frozen?
    end
  end

  # Bundled data is never optional: a missing list would leave `admin`
  # registrable without a word.
  def test_a_missing_data_file_is_a_data_error
    error = assert_raises(Usernames::DataError) { Usernames::Data.list("reserved/does-not-exist.txt") }

    assert_match(%r{data/reserved/does-not-exist\.txt is missing}, error.message)
    assert_kind_of Usernames::Error, error
  end

  def test_an_empty_or_malformed_data_file_is_a_data_error
    Dir.mktmpdir do |dir|
      empty = File.join(dir, "empty.txt").tap { |path| File.write(path, "# only a comment\n\n") }
      shapeless = File.join(dir, "leet.yml").tap { |path| File.write(path, "digits: [o, i]\n") }
      unparsable = File.join(dir, "hate.yml").tap { |path| File.write(path, "always: [unclosed\n") }
      shape = { "digits" => Hash, "offensive_only" => Hash }

      assert_match(/has no entries/, assert_raises(Usernames::DataError) { Usernames::Data.list(empty) }.message)
      assert_match(/needs "digits" \(a Hash\)/,
                   assert_raises(Usernames::DataError) { Usernames::Data.send(:yaml, shapeless, shape) }.message)
      assert_match(/can't be parsed/,
                   assert_raises(Usernames::DataError) { Usernames::Data.send(:yaml, unparsable, shape) }.message)
    end
  end

  # The whole gem, copied with one data file broken: requiring it fails,
  # naming the file, before a single name is checked.
  def test_a_broken_install_fails_when_the_gem_loads
    {
      "reserved/web.txt" => nil,
      "offensive/en.json" => %([{"term": "x", "severity": 9}]),
      "offensive/leet.yml" => "digits: {}\n",
      "offensive/es.json" => "[{"
    }.each do |file, content|
      output, status = require_a_copy_with(file, content)

      refute_predicate status, :success?, "#{file}: the gem loaded"
      assert_match(%r{data/#{Regexp.escape(file)} (is missing|is not a list|needs|can't be parsed)}, output)
      assert_match(/\(Usernames::DataError\)/, output)
    end
  end

  def test_the_bundled_data_loads
    assert_same Usernames::Data, Usernames::Data.load!
  end

  private

  # Copies lib/, config/ and data/ to a temporary root, replaces `file` under
  # data/ with `content` (or deletes it), and requires the gem from there.
  def require_a_copy_with(file, content)
    root = File.expand_path("../..", __dir__)
    Dir.mktmpdir do |dir|
      %w[lib config data].each { |part| FileUtils.cp_r(File.join(root, part), dir) }
      path = File.join(dir, "data", file)
      content.nil? ? File.delete(path) : File.write(path, content)
      script = %(require "bundler/setup"; require "usernames"; puts Usernames.allowed?("admin"))
      output, status = Open3.capture2e(RbConfig.ruby, "-I", File.join(dir, "lib"), "-e", script)
      [output, status]
    end
  end
end
