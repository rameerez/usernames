# frozen_string_literal: true

require "test_helper"

class ResultTest < UsernamesTestCase
  def test_members
    assert_equal %i[ok? reason rule canonical message], Usernames::Result.members
  end

  def test_an_allowed_name
    result = Usernames.check(" @Javi_R ")

    assert_predicate result, :ok?
    assert_nil result.reason
    assert_nil result.rule
    assert_nil result.message
    assert_equal "javi_r", result.canonical
  end

  def test_a_format_failure_names_the_reason_and_no_rule
    result = Usernames.check("_javi")

    refute_predicate result, :ok?
    assert_equal :username_edges, result.reason
    assert_nil result.rule
    assert_equal "_javi", result.canonical
    assert_equal "can't start or end with an underscore", result.message
  end

  def test_a_reserved_verdict
    Usernames::Reserved.stub(:verdict, :impersonation) do
      result = Usernames.check("Ad_min")

      refute_predicate result, :ok?
      assert_equal :username_reserved, result.reason
      assert_equal :impersonation, result.rule
      assert_equal "ad_min", result.canonical
      assert_equal "is reserved", result.message
    end
  end

  def test_an_offensive_verdict
    Usernames::Offensive.stub(:verdict, :hate_number) do
      result = Usernames.check("javi")

      assert_equal :username_not_allowed, result.reason
      assert_equal :hate_number, result.rule
      assert_equal "isn't allowed", result.message
    end
  end

  # D-13: never which word, never what was typed.
  def test_the_message_never_contains_the_input
    ["ja%{value}vi", "_%{count}_", "x\nadmin", "<script>"].each do |input|
      result = Usernames.check(input)

      refute_includes result.message, input.strip, input.inspect
    end
  end

  def test_results_are_immutable_values
    result = Usernames.check("javi")

    assert_predicate result, :frozen?
    assert_equal result, Usernames.check("javi")
    refute_respond_to result, :reason=
  end

  def test_with_returns_a_changed_copy
    result = Usernames.check("javi")

    assert_equal "other", result.with(canonical: "other").canonical
    assert_equal "javi", result.canonical
  end

  def test_failure_message_uses_a_symbol_message_as_the_translation
    failure = Usernames::Failure.new(reason: :username_characters,
                                     details: { message: :username_characters_without_separators,
                                                letters: Usernames::Phrase.letters(:lowercase) })

    assert_equal "can only contain lowercase letters and numbers", failure.message
    assert_nil failure.rule
  end

  def test_failure_defaults
    failure = Usernames::Failure.new(reason: :username_spaces)

    assert_equal({}, failure.details)
    assert_equal "can't contain spaces", failure.message
  end
end
