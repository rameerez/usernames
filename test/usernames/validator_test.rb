# frozen_string_literal: true

require "test_helper"

class ValidatorTest < UsernamesTestCase
  # A model class on the members table with the given declarations.
  def model(&declarations)
    Class.new(ApplicationRecord) do
      self.table_name = "members"
      def self.name = "Member"
      class_eval(&declarations)
    end
  end

  def errors_for(record)
    record.validate
    record.errors
  end

  # ---- The bare validator (Member, from the test helper) -----------------------

  def test_a_valid_username
    assert_predicate Member.new(username: "javi_r"), :valid?
  end

  def test_one_error_for_the_first_failing_rule
    errors = errors_for(Member.new(username: "_A"))

    details = errors.details[:username].map { |detail| detail.transform_values { |value| value.is_a?(Usernames::Phrase) ? value.to_s : value } }
    expected = { error: :username_characters, count: 1, letters: "lowercase letters", separators_phrase: "underscores" }

    assert_equal [expected], details
    assert_equal ["Username can only contain lowercase letters, numbers and underscores"], errors.full_messages
  end

  def test_every_format_rule_reaches_the_record
    {
      "ja vi" => :username_spaces, "ja.vi" => :username_characters, "jos\u{E9}" => :username_unicode,
      "ab" => :too_short, "a" * 31 => :too_long, "_javi" => :username_edges,
      "ja__vi" => :username_consecutive, "12345" => :username_digits_only
    }.each do |value, type|
      errors = errors_for(Member.new(username: value))

      assert errors.of_kind?(:username, type), "#{value.dump} → #{errors.details.inspect}"
      assert_equal 1, errors.size
    end
  end

  def test_nil_is_skipped
    assert_predicate Member.new(username: nil), :valid?
  end

  # Without `normalizes`, an empty string is a value like any other.
  def test_an_empty_string_is_too_short
    assert errors_for(Member.new(username: "")).of_kind?(:username, :too_short)
  end

  # PRD §6.2: validate what you store.
  def test_validates_the_value_as_supplied
    assert errors_for(Member.new(username: "Javi")).of_kind?(:username, :username_characters)
    assert errors_for(Member.new(username: " javi")).of_kind?(:username, :username_spaces)
    assert errors_for(Member.new(username: "@javi")).of_kind?(:username, :username_characters)
  end

  def test_paired_with_normalizes_typed_case_and_at_are_fine
    normalized = model do
      normalizes :username, with: Usernames.normalizer
      validates :username, username: true
    end

    record = normalized.new(username: "  @Javi_R ")

    assert_predicate record, :valid?
    assert_equal "javi_r", record.username
  end

  def test_a_newline_never_passes
    assert errors_for(Member.new(username: "x\nadmin")).of_kind?(:username, :username_spaces)
  end

  # Rails itself calls `value.blank?` before any EachValidator runs, and that
  # raises on invalid UTF-8 — for every validator, not only this one (and
  # Action Dispatch refuses such parameters before they reach a model). With
  # `normalizes` the bytes are dropped first; the rules on their own refuse
  # them (format_rules_test).
  def test_broken_bytes_are_dropped_by_the_normalizer_before_validation
    normalized = model do
      normalizes :username, with: Usernames.normalizer
      validates :username, username: true
    end

    record = normalized.new(username: "ja\xFFvi")

    assert_predicate record, :valid?
    assert_equal "javi", record.username
  end

  def test_a_number_assigned_to_a_string_column
    assert errors_for(Member.new(username: 12_345)).of_kind?(:username, :username_digits_only)
  end

  def test_a_plain_active_model_attribute
    form = Class.new do
      include ActiveModel::Model

      attr_accessor :username

      def self.name = "SignupForm"
      validates :username, username: true
    end

    assert_predicate form.new(username: "javi"), :valid?
    refute_predicate form.new(username: :Javi), :valid?
  end

  # ---- Options -----------------------------------------------------------------

  def test_message_replaces_every_rules_message
    custom = model { validates :username, username: { message: "isn't available" } }

    %w[_javi ab ja.vi 12345].each do |value|
      errors = errors_for(custom.new(username: value))

      assert_equal ["isn't available"], errors[:username], value
    end
  end

  def test_message_keeps_the_error_type
    custom = model { validates :username, username: { message: "isn't available" } }

    assert errors_for(custom.new(username: "_javi")).of_kind?(:username, :username_edges)
  end

  def test_message_can_name_a_translation
    I18n.backend.store_translations(:en, errors: { messages: { handle_unavailable: "is unavailable" } })
    custom = model { validates :username, username: { message: :handle_unavailable } }

    assert_equal ["is unavailable"], errors_for(custom.new(username: "_javi"))[:username]
  end

  def test_message_replaces_the_without_separators_message_too
    custom = model { validates :username, username: { separators: [], message: "nope" } }

    assert_equal ["nope"], errors_for(custom.new(username: "ja_vi"))[:username]
  end

  def test_per_call_rules
    custom = model { validates :username, username: { length: 2..15, separators: %w[_ .] } }

    assert_predicate custom.new(username: "jd"), :valid?
    assert_predicate custom.new(username: "j.d"), :valid?
    assert errors_for(custom.new(username: "a" * 16)).of_kind?(:username, :too_long)
    assert errors_for(custom.new(username: "j.json")).of_kind?(:username, :username_extension)
  end

  def test_per_call_case_preserve
    custom = model { validates :handle, username: { case: :preserve } }

    assert_predicate custom.new(handle: "JaVi"), :valid?
  end

  def test_per_call_rules_leave_the_global_configuration_alone
    model { validates :username, username: { length: 2..15 } }

    assert_equal 3..30, Usernames.configuration.length
    refute_predicate Member.new(username: "jd"), :valid?
  end

  def test_unknown_options_fail_when_the_model_is_defined
    error = assert_raises(Usernames::ConfigurationError) { model { validates :username, username: { lenght: 2..15 } } }

    assert_match(/unknown option :lenght/, error.message)
  end

  def test_bad_values_fail_when_the_model_is_defined
    error = assert_raises(Usernames::ConfigurationError) { model { validates :username, username: { length: 3 } } }

    assert_match(/length must be a Range/, error.message)
  end

  def test_the_configuration_is_read_at_validation_time
    record = Member.new(username: "jd")

    refute_predicate record, :valid?
    with_config(length: 2..30) { assert_predicate record, :valid? }
  end

  def test_rails_conditions_still_apply
    conditional = model { validates :username, username: true, if: -> { false } }

    assert_predicate conditional.new(username: "_"), :valid?
  end

  def test_allow_blank
    blank_ok = model { validates :username, username: true, allow_blank: true }

    assert_predicate blank_ok.new(username: ""), :valid?
  end

  def test_strict_raises
    strict = model { validates :username, username: true, strict: true }

    error = assert_raises(ActiveModel::StrictValidationFailed) { strict.new(username: "_javi").validate }
    assert_match(/can't start or end with an underscore/, error.message)
  end

  def test_validates_username_of
    helper = model { validates_username_of :username, length: 2..15 }

    assert_predicate helper.new(username: "jd"), :valid?
    assert errors_for(helper.new(username: "_jd")).of_kind?(:username, :username_edges)
  end

  def test_validates_username_of_several_attributes
    helper = model { validates_username_of :username, :handle }

    errors = errors_for(helper.new(username: "_a_", handle: "ab"))

    assert errors.of_kind?(:username, :username_edges)
    assert errors.of_kind?(:handle, :too_short)
  end

  # ---- Content rules go through the same pipeline ----------------------------------

  def test_a_reserved_verdict_becomes_username_reserved
    Usernames::Reserved.stub(:verdict, :impersonation) do
      errors = errors_for(Member.new(username: "ad_min"))

      assert errors.of_kind?(:username, :username_reserved)
      assert_equal ["is reserved"], errors[:username]
    end
  end

  def test_an_offensive_verdict_becomes_username_not_allowed
    Usernames::Offensive.stub(:verdict, :severe) do
      assert_equal ["isn't allowed"], errors_for(Member.new(username: "javi"))[:username]
    end
  end

  def test_content_rules_receive_the_comparison_key
    keys = []
    custom = model { validates :handle, username: { case: :preserve } }

    Usernames::Reserved.stub(:verdict, ->(key, _rules) { (keys << key) && nil }) do
      custom.new(handle: "JaVi").validate
    end

    assert_equal ["javi"], keys
  end

  # ---- Messages: translated, per model, never the value -------------------------------

  def test_a_per_model_translation_wins
    I18n.backend.store_translations(:en, activerecord: { errors: { models: { member: { attributes: { username: {
                                      username_edges: "can't have an underscore at either end"
                                    } } } } } })

    assert_equal ["can't have an underscore at either end"], errors_for(Member.new(username: "_javi"))[:username]
  ensure
    I18n.backend.reload!
  end

  def test_messages_follow_the_locale_they_are_read_in
    errors = errors_for(Member.new(username: "ja.vi"))

    assert_equal ["can only contain lowercase letters, numbers and underscores"], errors[:username]
    I18n.with_locale(:es) do
      assert_equal ["solo puede contener letras minúsculas, números y guiones bajos"], errors[:username]
    end
  end

  def test_messages_never_contain_the_value
    ["ja%{value}vi", "_%{count}_", "x%%y"].each do |value|
      messages = errors_for(Member.new(username: value)).full_messages

      refute(messages.any? { |message| message.include?(value) }, messages.inspect)
    end
  end

  def test_error_details_serialize_as_text
    details = errors_for(Member.new(username: "ja.vi")).details[:username].first

    assert_equal "underscores", details[:separators_phrase].as_json
    # as_json, not to_json: Rails 7.2 and 8.0 pass json 3.x an option it no
    # longer takes, for any object at all.
    assert_equal "underscores", details.as_json["separators_phrase"]
  end
end
