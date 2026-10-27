# frozen_string_literal: true

require "test_helper"

# Offensive words (PRD §10): the corpora gates, the §10.2 fixture table,
# hate rules, severity modes and adapters.
class OffensiveTest < UsernamesTestCase
  CORPORA = File.expand_path("../corpora", __dir__)
  DOTS = { separators: %w[_ .] }.freeze
  OFFENSIVE_RULES = %i[severe strong hate_number adapter].freeze

  def corpus(name)
    File.readlines(File.join(CORPORA, name), chomp: true).reject { |line| line.start_with?("#") || line.strip.empty? }
  end

  def rules(**)
    Usernames.configuration.rules_for(**)
  end

  # The offensive matcher alone, on the comparison key, as PRD §10.6 runs the corpora.
  def offensive(name, **)
    options = { separators: %w[_ . -], ** }
    rules = rules(**options)
    Usernames::Offensive.verdict(rules.normalize(name), rules)
  end

  def rejected?(name, **)
    !Usernames.check(name, **DOTS, **).ok?
  end

  # --- §10.6 gates --------------------------------------------------------------------------------

  def test_gate_legitimate_names_are_never_refused_at_strong
    names = corpus("legitimate.txt") + corpus("first_names.txt") + corpus("surnames.txt")
    by_matcher = names.select { |name| offensive(name, offensive: { severity: :strong }) }
    by_check = names.select do |name|
      Usernames.check(name, offensive: { severity: :strong }).reason == :username_not_allowed
    end

    puts "\n  legitimate gate: #{names.size} names, #{by_matcher.size} refused by the matcher, " \
         "#{by_check.size} by Usernames.check"

    assert_empty by_matcher
    assert_empty by_check
  end

  # legitimate.txt is lexical safety (the offensive matcher only: `ho` is too
  # short to register, and that is not this gate's business); eligible.txt is
  # whole usernames, which must pass every rule.
  def test_gate_eligible_usernames_pass_every_rule
    refused = corpus("eligible.txt").filter_map do |name|
      result = Usernames.check(name)
      "#{name} (#{result.reason})" unless result.ok?
    end

    assert_empty refused
  end

  def test_gate_every_evasion_is_refused
    names = corpus("offensive.txt")
    passed_matcher = names.reject { |name| offensive(name) }
    passed_check = names.reject { |name| rejected?(name) }

    puts "\n  offensive gate: #{names.size} evasions, #{passed_matcher.size} passed the matcher, " \
         "#{passed_check.size} passed Usernames.check"

    assert_empty passed_matcher
    assert_empty passed_check
  end

  # Diagnostic only (PRD §10.6): never a gate, the count is printed.
  def test_dictionary_collisions_are_counted
    words = corpus("words_en_50k.txt")
    hits = words.select { |word| offensive(word) }

    puts "\n  dictionary collisions at :strong: #{hits.size} of #{words.size} (#{hits.first(12).join(' ')} …)"

    assert_operator hits.size, :<, words.size / 100
  end

  # --- §10.2 consequences -------------------------------------------------------------------------

  FIXTURES = {
    "scunthorpe" => true, "scunthorpe_united" => true, "scunthorpeunited" => false, "scunt_horpe" => false,
    "scunthorpe_fuck" => false, "f.u.c.k" => false, "fu_ck" => false, "sus.sex" => false, "cunt" => false,
    "s.cunt.horpe" => false, "grape" => true, "therapist" => true, "gr_ape" => false, "ther_apist" => false
  }.freeze

  def test_the_prd_fixture_table
    FIXTURES.each do |name, ok|
      result = Usernames.check(name, **DOTS)

      assert_equal ok, result.ok?, "#{name}: #{result.reason} #{result.rule}"
      assert_equal :username_not_allowed, result.reason, name unless ok
    end
  end

  def test_which_rule_refused
    assert_equal :severe, Usernames.check("scunt_horpe").rule
    assert_equal :severe, Usernames.check("gr_ape").rule
    assert_equal :strong, Usernames.check("sus.sex", **DOTS).rule
  end

  def test_negro_passes_in_every_locale_and_mode
    [%i[en], %i[es], %i[en es]].product(%i[severe strong mild off]).each do |languages, severity|
      assert_predicate Usernames.check("negro", offensive: { languages: languages, severity: severity }), :ok?,
                       "#{languages} #{severity}"
    end
  end

  def test_segments_come_from_both_forms
    %w[shithead1 shithead2 sh1thead sh1thead_bob shithead_bob n1gger xxfuckxx BigCunt].each do |name|
      refute_predicate Usernames.check(name, **DOTS), :ok?, name
    end
    %w[admin1bob admin2bob].each { |name| assert_equal :username_reserved, Usernames.check(name).reason, name }
  end

  def test_exemptions_are_whole_segments_of_their_own_locale
    assert Usernames.allowed?("cocoon")
    assert Usernames.allowed?("sussex_fan")
    refute Usernames.allowed?("sussexfuck")
    assert Usernames.allowed?("computadora")
  end

  def test_config_offensive_allowed_exempts_segments_and_whole_names
    refute Usernames.allowed?("sus.sex", **DOTS)
    assert Usernames.allowed?("sus.sex", **DOTS, offensive: { allowed: %w[sex] })
    assert Usernames.allowed?("scunthorpeunited", offensive: { allowed: %w[ScunthorpeUnited] })
    assert Usernames.allowed?("sussex", offensive: { allowed: %w[sussex] })
    # A joined whole never becomes an exemption: the occurrence straddles a separator.
    refute Usernames.allowed?("fu_ck", offensive: { allowed: %w[fuck] })
  end

  def test_config_offensive_allowed_never_lifts_hate_rules
    refute Usernames.allowed?("hh88", offensive: { allowed: %w[hh88 hh] })
    refute Usernames.allowed?("heil_hitler", offensive: { allowed: %w[heil hitler heil_hitler] })
  end

  # --- hate rules (§10.3) -------------------------------------------------------------------------

  def test_hate_numbers
    %w[1488 14_88 x1488 8814x 1_488 148.8 hh88 hh_88 heil88 88hitler combat18 14words heil_hitler siegheil
       wpww_bob h3il88].each do |name|
      assert_equal :hate_number, offensive(name), name
    end
  end

  def test_numbers_alone_are_not_evidence
    %w[mike88 31488210 x1888 ahh88 combat1888 room420 agent69 band311 love88].each do |name|
      assert_nil offensive(name), name
    end
    assert Usernames.allowed?("mike88")
  end

  def test_whole_tokens_are_per_locale
    assert_equal :hate_number, offensive("kkk")
    assert_equal :hate_number, offensive("kkk", offensive: { languages: %i[en] })
    assert_nil offensive("kkk", offensive: { languages: %i[es] })
    assert_nil offensive("kkkx", offensive: { languages: %i[en] })
    assert_equal :hate_number, offensive("zog_x", offensive: { languages: %i[en] })
  end

  # --- modes (§10.5) ------------------------------------------------------------------------------

  def test_severity_modes
    assert_equal :severe, offensive("cunt", offensive: { severity: :severe })
    assert_nil offensive("sus.sex", offensive: { severity: :severe })
    assert_equal :hate_number, offensive("hh88", offensive: { severity: :severe })

    assert_equal :strong, offensive("sus.sex")
    assert_nil offensive("dick_tracy")
    assert_nil offensive("hell_norway")

    assert_equal :strong, offensive("dick_tracy", offensive: { severity: :mild })
    assert_equal :strong, offensive("hell_norway", offensive: { severity: :mild })
  end

  def test_off_runs_no_bundled_check_but_still_the_adapters
    off = { offensive: { severity: :off } }

    assert_nil offensive("cunt", **off)
    assert_nil offensive("hh88", **off)
    assert_nil offensive("kkk", **off)
    assert_equal :adapter, offensive("javi", offensive: { severity: :off, adapters: [->(_name) { true }] })
  end

  # A language that ships no words would refuse nothing, so naming one is a
  # configuration error rather than a silently weaker check.
  def test_a_language_without_data_is_refused
    assert_equal %i[en es], Usernames::Data.available_locales
    error = assert_raises(Usernames::ConfigurationError) { offensive("cunt", offensive: { languages: %i[pt] }) }

    assert_match(/no word list for :pt \(available: :en, :es\)/, error.message)
  end

  # --- adapters (§10.4) ---------------------------------------------------------------------------

  def test_callable_adapters
    seen = []
    adapter = lambda do |name|
      seen << name
      name.include?("bad")
    end

    assert_equal :adapter, offensive("very_bad", offensive: { adapters: [adapter] })
    assert_nil offensive("Very_Good", offensive: { adapters: [adapter] }, case: :preserve)
    assert_equal %w[very_bad Very_Good], seen, "adapters get the name as stored"
  end

  def test_adapters_run_only_after_the_bundled_checks_pass
    assert_equal :severe, offensive("cunt", offensive: { adapters: [->(_name) { flunk "asked" }] })
  end

  def test_a_raising_adapter_is_skipped_and_logged_under_allow
    broken = ->(_name) { raise IOError, "service down" }
    log = capture_log { assert_nil offensive("javi", offensive: { adapters: [broken, ->(_name) { false }] }) }

    assert_match(/\[usernames\] offensive adapter .* raised IOError: service down \(skipped/, log)
  end

  def test_a_raising_adapter_rejects_under_reject
    broken = ->(_name) { raise IOError, "service down" }
    log = capture_log do
      assert_equal :adapter, offensive("javi", offensive: { adapters: [broken] }, on_adapter_failure: :reject)
    end

    assert_match(/name rejected/, log)
  end

  def test_without_a_rails_logger_failures_go_to_stderr
    broken = ->(_name) { raise IOError, "service down" }

    Rails.stub(:logger, nil) do
      assert_output(nil, /\[usernames\] offensive adapter/) do
        assert_nil offensive("javi", offensive: { adapters: [broken] })
      end
    end
  end

  def test_the_moderate_adapter_is_a_no_op_without_moderate
    refute defined?(::Moderate)
    refute_predicate Usernames::Adapters::Moderate, :available?
    refute Usernames::Adapters::Moderate.call("anything")
    assert_nil offensive("javi", offensive: { adapters: [:moderate] })
  end

  def test_the_moderate_adapter_calls_the_wordlist_with_readable_text
    asked = []
    wordlist = Class.new do
      define_singleton_method(:classify) do |text|
        asked << text
        Struct.new(:flagged?).new(text.downcase.include?("wolf"))
      end
    end
    Object.const_set(:Moderate, Module.new)
    Moderate.const_set(:Filters, Module.new)
    Moderate::Filters.const_set(:Wordlist, wordlist)

    assert_equal :adapter, offensive("big_bad_wolf", offensive: { adapters: [:moderate] })
    assert_nil offensive("javi", offensive: { adapters: [:moderate] })
    assert_equal :adapter, offensive("BigBadWolf", offensive: { adapters: [:moderate] }, case: :preserve)
    assert_equal ["big bad wolf", "javi", "Big Bad Wolf"], asked
    assert_equal "Big Bad Wolf x HTML Parser", Usernames::Adapters::Moderate.text_for("BigBadWolf_x.HTMLParser")
  ensure
    Object.send(:remove_const, :Moderate) if defined?(::Moderate)
  end

  # --- the matcher's building blocks --------------------------------------------------------------

  def test_fold_is_the_leet_table_then_the_offensive_rewrites
    assert_equal "shithead", Usernames::Offensive.fold("sh1th34d")
    assert_equal "fuck", Usernames::Offensive.fold("phuck")
    assert_equal "wanker", Usernames::Offensive.fold("vvanker")
    assert_equal "seks_2", Usernames::Offensive.fold("sex_2")
    assert_equal "fuck", Usernames::Offensive.fold("fvck"), "v → u, after vv → w"
    assert_equal "fuuck", Usernames::Offensive.fold("fuuuuuck"), "a stretch is cut to two"
    assert_equal "fuuck", Usernames::Offensive.fold("fuuck"), "a double is left alone"
    assert_equal "book_assess", Usernames::Offensive.fold("book_assess")
  end

  # The evasions that split a rewrite, or stretch a letter, past the old fold.
  def test_rewrites_across_separators_and_stretches
    %w[p_huck fvck f_vck fuuuuuck fuuuu_ck fuu_uuck p.h.u.c.k].each do |name|
      result = Usernames.check(name, **DOTS)

      assert_equal :username_not_allowed, result.reason, name
    end
  end

  # A character a rewrite makes out of two parts belongs to both: an
  # occurrence over it straddles them (rule a-2), whatever the segments say.
  def test_a_rewrite_across_a_separator_straddles_it
    whole = Usernames::Offensive::Name.new("p_huck").wholes.last

    assert_equal "fuck", whole.text
    assert whole.straddles?("fuck", 0)
    assert_equal %w[p huck], whole.segments, "each segment is folded on its own"
    refute Usernames::Offensive::Name.new("phuck").wholes.last.straddles?("fuck", 0)
  end

  # Exemptions are still whole segments: a rewrite inside an exempt word
  # keeps it exempt, and one across a separator never manufactures one.
  def test_exemption_boundaries_survive_the_rewrites
    assert_predicate Usernames.check("sussex_bob"), :ok?
    assert_predicate Usernames.check("savvy_vivian"), :ok?
    refute_predicate Usernames.check("sus_sex"), :ok?
    refute_predicate Usernames.check("sussex_fvck"), :ok?
  end

  # --- case boundaries, in preserve mode -----------------------------------------------------------

  # A capital is a word boundary the person typed: in preserve mode it cuts
  # a segment into words, for the strong terms and for the exemptions alike.
  def test_a_capital_separates_words_in_preserve_mode
    assert_equal :username_not_allowed, Usernames.check("ShitheadBob", case: :preserve).reason
    assert_predicate Usernames.check("ScunthorpeUnited", case: :preserve), :ok?
    assert_predicate Usernames.check("SpicyFlash", case: :preserve), :ok?
    assert_predicate Usernames.check("GrapeJuice", case: :preserve), :ok?
    assert_equal :username_not_allowed, Usernames.check("ScunthorpeFuck", case: :preserve).reason
    assert_equal :username_not_allowed, Usernames.check("FuCk", case: :preserve).reason
  end

  # Lowercase mode stores no case, so there is no boundary to read: the
  # same names are one glued segment each.
  def test_lowercase_mode_reads_the_same_names_as_one_segment
    assert_predicate Usernames.check("ShitheadBob"), :ok?
    assert_equal :username_not_allowed, Usernames.check("ScunthorpeUnited").reason
    assert_predicate Usernames.check("SpicyFlash"), :ok?
  end

  # Glued lowercase words are a documented limit: with no capital and no
  # separator there is nothing to split them by, in either mode.
  def test_glued_lowercase_words_pass_at_strong
    assert_predicate Usernames.check("shitheadbob"), :ok?
    assert_predicate Usernames.check("shitheadbob", case: :preserve), :ok?
    assert_equal :username_not_allowed, Usernames.check("shithead_bob").reason
  end

  # The glued segment stays, and each word is added, in both forms; an
  # occurrence across a boundary is judged by the glued segment.
  def test_case_boundaries_add_words_to_the_segments
    name = Usernames::Offensive::Name.new("sh1theadbob_x", "Sh1theadBob_x")

    assert_equal %w[sh theadbob thead bob x shitheadbob shithead ks], name.segments
    assert_equal %w[sh1theadbobx shitheadbobks], name.wholes.map(&:text), "the wholes are unchanged"

    whole = Usernames::Offensive::Name.new("scunthorpe", "ScunThorpe").wholes.first

    assert_equal "scun", whole.segment_at(0, 4)
    assert_equal "scunthorpe", whole.segment_at(1, 4), "across a boundary: the glued segment"
    assert_predicate Usernames.check("ScunThorpe", case: :preserve), :ok?
  end

  def test_name_forms
    name = Usernames::Offensive::Name.new("sh1t_head2")

    assert_equal %w[sh1t_head2 shit_head2], name.forms
    assert_equal %w[sh t head shit], name.segments
    assert_equal %w[sh1t head2], name.digit_parts
    assert_equal %w[sh1thead2 shithead2], name.wholes.map(&:text)
  end

  # Short terms, segment-only terms and terms spelled with a digit, which the
  # bundled data has few or none of, on a lexicon of their own.
  SPECIAL_TERMS = [
    { "term" => "gc", "severity" => 4, "variants" => [], "tags" => [], "exceptions" => [] },
    { "term" => "grim", "severity" => 4, "variants" => [], "tags" => [], "exceptions" => ["grimace"],
      "segment_only" => false },
    { "term" => "boo", "severity" => 4, "variants" => ["b00s"], "tags" => [], "exceptions" => [],
      "segment_only" => true },
    { "term" => "2g1c", "severity" => 4, "variants" => [], "tags" => [], "exceptions" => [] },
    { "term" => "masturb8", "severity" => 3, "variants" => [], "tags" => [], "exceptions" => [] }
  ].freeze

  def test_short_digit_and_segment_only_terms
    lexicon = Usernames::Data.stub(:offensive, SPECIAL_TERMS) do
      Usernames::Data.stub(:allowlist, %w[grimsby]) { Usernames::Offensive::Lexicon.new(:zz) }
    end
    severe = ->(key) { lexicon.severe?(Usernames::Offensive::Name.new(key), Set.new) }
    strong = ->(key) { lexicon.strong?(Usernames::Offensive::Name.new(key), 3, Set.new) }

    assert severe.call("gc")
    assert severe.call("x_gc")
    refute severe.call("gcastro")
    assert severe.call("grimly")
    refute severe.call("grimace")
    refute severe.call("grimsby")
    assert severe.call("boos")
    refute severe.call("booster")
    assert severe.call("x2g1c")
    refute severe.call("2g1")
    assert strong.call("masturb8")
    assert strong.call("x_masturb8")
    refute strong.call("masturb88")
  end

  def test_lexicons_are_compiled_once_per_language
    assert_same Usernames::Offensive::Lexicon.for(:en), Usernames::Offensive::Lexicon.for("en")
  end
end
