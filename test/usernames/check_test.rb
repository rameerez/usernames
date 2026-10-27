# frozen_string_literal: true

require "test_helper"

# The pure functions on the Usernames module.
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

  # Reserved words are matched on the comparison key; the offensive matcher
  # gets the name as stored, so it can read the case it was typed in.
  def test_content_rules_get_the_name_and_the_rules_in_force
    seen = nil
    reserved = nil
    verdict = Usernames::Reserved.method(:verdict)
    Usernames::Reserved.stub(:verdict, ->(key, rules) { (reserved = key) && verdict.call(key, rules) }) do
      Usernames::Offensive.stub(:verdict, ->(name, rules) { (seen = [name, rules]) && nil }) do
        Usernames.check("JaVi", case: :preserve, offensive: { severity: :severe })
      end
    end

    assert_equal "javi", reserved
    assert_equal "JaVi", seen.first
    assert_equal :severe, seen.last.offensive.severity
  end

  def test_content_verdicts_reach_the_result
    assert_equal(%i[username_reserved impersonation], Usernames.check("Ad_min").then { [_1.reason, _1.rule] })
    assert_equal(%i[username_not_allowed severe], Usernames.check("BigCunt").then { [_1.reason, _1.rule] })
    assert_equal "is reserved", Usernames.check("Ad_min").message
  end

  def test_generate_and_candidates_for
    assert_predicate Usernames.check(Usernames.generate), :ok?
    assert_equal "jose_garcia", Usernames.generate(from: "Jos\u{E9} Garc\u{ED}a")
    assert_equal "javi_r", Usernames.candidates_for("Javi R", count: 5).first
  end

  def test_error_classes
    assert_operator Usernames::Error, :<, StandardError
    assert_operator Usernames::ConfigurationError, :<, Usernames::Error
    assert_operator Usernames::NoFreeNameError, :<, Usernames::Error
  end

  # The version is the newest release in the CHANGELOG: a bump that forgets
  # one or the other fails here.
  def test_version
    changelog = File.read(File.expand_path("../../CHANGELOG.md", __dir__))
    newest = changelog[/^## \[(\d+\.\d+\.\d+)\]/, 1]

    assert_equal newest, Usernames::VERSION
  end
end
