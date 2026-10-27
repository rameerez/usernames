# frozen_string_literal: true

require "test_helper"

# The pure functions on the Usernames module (PRD §6.3).
class CheckTest < UsernamesTestCase
  def test_check_normalises_then_applies_the_rules
    result = Usernames.check("  @Javi_R ")

    assert_predicate result, :ok?
    assert_equal "javi_r", result.canonical
  end

  def test_check_takes_per_call_options
    assert_predicate Usernames.check("jd", length: 2..15), :ok?
    refute_predicate Usernames.check("jd"), :ok?
  end

  def test_check_raises_for_bad_options
    assert_raises(Usernames::ConfigurationError) { Usernames.check("javi", length: "short") }
  end

  def test_check_never_raises_on_odd_values
    [nil, 42, :javi, "ja\xFFvi", "Javi".encode("UTF-16LE"), "a" * 54_000, "\u{0}", "\u{1F600}" * 40].each do |value|
      assert_kind_of Usernames::Result, Usernames.check(value), value.inspect[0, 40]
    end
  end

  def test_allowed_is_check_ok
    assert Usernames.allowed?("javi")
    refute Usernames.allowed?("_javi")
    assert Usernames.allowed?("j.d", separators: %w[_ .])
  end

  # Structure before content: a name that fails a format rule never reaches
  # the reserved or offensive matchers.
  def test_content_rules_run_only_on_well_formed_names
    asked = []
    record = ->(key, _rules) { (asked << key) && nil }

    Usernames::Reserved.stub(:verdict, record) do
      Usernames::Offensive.stub(:verdict, record) do
        Usernames.check("_javi")
        Usernames.check("Javi_R")
      end
    end

    assert_equal %w[javi_r javi_r], asked
  end

  def test_reserved_is_asked_before_offensive
    Usernames::Reserved.stub(:verdict, :exact) do
      Usernames::Offensive.stub(:verdict, ->(*) { flunk "offensive asked about a reserved name" }) do
        assert_equal :username_reserved, Usernames.check("javi").reason
      end
    end
  end

  def test_content_rules_get_the_comparison_key_and_the_rules_in_force
    seen = nil
    Usernames::Offensive.stub(:verdict, ->(key, rules) { (seen = [key, rules]) && nil }) do
      Usernames.check("JaVi", case: :preserve, offensive: { severity: :severe })
    end

    assert_equal "javi", seen.first
    assert_equal :severe, seen.last.offensive.severity
  end

  def test_the_phase_one_content_matchers_allow_everything
    assert_nil Usernames::Reserved.verdict("admin", Usernames.configuration.rules_for)
    assert_nil Usernames::Offensive.verdict("admin", Usernames.configuration.rules_for)
  end

  def test_generate_and_candidates_for_are_not_available_yet
    assert_raises(NotImplementedError) { Usernames.generate }
    assert_raises(NotImplementedError) { Usernames.generate(from: "Jos\u{E9} Garc\u{ED}a") }
    assert_raises(NotImplementedError) { Usernames.candidates_for("Javi R", count: 5) }
  end

  def test_error_classes
    assert_operator Usernames::Error, :<, StandardError
    assert_operator Usernames::ConfigurationError, :<, Usernames::Error
    assert_operator Usernames::NoFreeNameError, :<, Usernames::Error
  end

  def test_version
    assert_equal "0.1.0", Usernames::VERSION
  end
end
