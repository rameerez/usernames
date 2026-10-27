# frozen_string_literal: true

require "test_helper"

# A profile form that saves with `save(context: :profile)`: the name is asked
# for there, and nowhere else.
class ProfileUser < ApplicationRecord
  self.table_name = "users"
  has_username required: { on: :profile }
end

# Generated names that start from the person's own name.
class SeededUser < ApplicationRecord
  self.table_name = "users"
  has_username seed: :name
end

# A saved name stays: it can change, but not be saved blank.
class KeptUser < ApplicationRecord
  self.table_name = "users"
  has_username clearable: false
end

class ModelOptionsTest < UsernamesTestCase
  # A generated name in the default shape: adjective_noun_digits.
  GENERATED = /\A[a-z]+_[a-z]+_\d{2}\z/

  def setup
    super
    User.delete_all
  end

  def teardown
    User.delete_all
    super
  end

  def take(name)
    User.insert_all([{ username: name, email: "rival-#{SecureRandom.hex(4)}@example.com" }])
  end

  def legacy(model, username)
    email = "legacy-#{SecureRandom.hex(4)}@example.com"
    User.insert_all([{ username: username, email: email }])
    model.find_by!(email: email)
  end

  def model(**options, &)
    Class.new(ApplicationRecord) do
      self.table_name = "users"
      def self.name = "OptionsUser"

      has_username(**options)
      class_eval(&) if block_given?
    end
  end

  # --- required: { on: } ----------------------------------------------------------------------------

  def test_required_on_a_context_generates_outside_it
    user = ProfileUser.create!(email: "a@example.com")

    assert_predicate user, :username_generated?, "signing up is not the profile form"
  end

  def test_required_on_a_context_is_presence_in_that_context
    user = ProfileUser.create!(email: "a@example.com")
    user.username = nil

    assert user.save, "outside the context a name may still be cleared (clearable: true)"
    refute user.save(context: :profile)
    assert_equal [{ error: :blank }], user.errors.details[:username]

    user.username = "ana"

    assert user.save(context: :profile)
    assert_equal "ana", user.reload.username
  end

  # The deliberate exception to grandfathering: the profile form is where
  # the person types one, so there even an unchanged legacy blank must be
  # filled. Anywhere else it saves unrelated changes, as always.
  def test_required_on_a_context_asks_an_unchanged_legacy_blank_there
    [nil, "", "  "].each do |blank|
      user = legacy(ProfileUser, blank)

      assert user.update(name: "Unrelated"), "unrelated, over #{blank.inspect}"
      user.name = "Profile"

      refute user.save(context: :profile), blank.inspect
      assert_equal [{ error: :blank }], user.errors.details[:username]
    end
  end

  def test_a_new_record_validated_in_the_context_is_not_generated
    user = ProfileUser.new(email: "a@example.com")

    refute user.save(context: :profile)
    assert_nil user.username
    assert_equal [{ error: :blank }], user.errors.details[:username]
  end

  def test_required_on_several_contexts_match_by_intersection
    user = model(required: { on: %i[profile onboarding] }).create!(email: "a@example.com")
    user.username = nil

    refute user.valid?(:onboarding)
    refute user.valid?(:profile)
    refute user.valid?(%i[import profile])
    assert user.valid?(:import)
    assert_predicate user, :valid?
  end

  def test_required_on_a_context_with_generate_true_fills_a_new_record_there
    user = model(required: { on: :profile }, generate: true).new(email: "a@example.com")

    assert user.save(context: :profile)
    assert_predicate user, :username_generated?
  end

  def test_required_on_a_context_rejects_any_other_shape
    [{ on: "profile" }, { on: [] }, { on: [:profile, "x"] }, { if: :x }, { on: :profile, if: :x }, {}].each do |given|
      error = assert_raises(Usernames::ConfigurationError, given.inspect) { model(required: given) }

      assert_match(/required: takes \{ on: :context \}/, error.message)
    end
  end

  # --- generation is for new records, whatever the context -------------------------------------------

  # In 0.1 generation ran `on: :create`, which an explicit context replaces:
  # `save(context: :import)` left a new record without a name.
  def test_a_new_record_validated_in_a_custom_context_is_generated
    user = User.new(email: "a@example.com")

    assert user.save(context: :import)
    assert_predicate user, :username_generated?
    assert_match GENERATED, user.username
  end

  def test_generate_true_fills_a_new_record_in_a_custom_context
    user = model(generate: true).new(email: "a@example.com")

    assert user.save(context: :import)
    assert_predicate user.username, :present?
  end

  def test_a_persisted_record_is_never_generated
    user = User.create!(email: "a@example.com")
    user.username = nil

    assert user.save(context: :import)
    assert_nil user.reload.username
  end

  def test_running_out_in_a_custom_context_is_one_error
    take("only_candidate")
    with_config(generator: ->(_attempt) { "only_candidate" }) do
      user = User.new(email: "a@example.com")

      refute user.save(context: :import)
      assert_equal [{ error: :username_unavailable }], user.errors.details[:username]
    end
  end

  # --- seed: ----------------------------------------------------------------------------------------

  def test_seed_starts_a_generated_name_from_the_value
    user = SeededUser.create!(email: "a@example.com", name: "Ana García")

    assert_equal "ana_garcia", user.username
    assert_predicate user, :username_generated?
  end

  def test_a_taken_seed_moves_on_to_a_numbered_one
    take("ana")

    assert_match(/\Aana_\d{2,3}\z/, SeededUser.create!(email: "a@example.com", name: "Ana").username)
  end

  # Six seeded slots, then fourteen of the default shape: a seed with every
  # numbered form taken still ends in a name.
  def test_a_seed_whose_every_form_is_taken_falls_through_to_the_default_shape
    names = []
    Usernames::Generator.stub(:with_digits, ->(base, _range, _rules) { (names << base) && "#{base}_11" }) do
      take("ana")
      take("ana_11")

      assert_match GENERATED, SeededUser.create!(email: "a@example.com", name: "Ana").username
    end
    assert_equal %w[ana] * 5, names, "three two-digit and two three-digit forms"
  end

  def test_a_blank_or_unusable_seed_draws_the_default_shape
    ["", " ", nil, "😀", "___"].each do |name|
      user = SeededUser.create!(email: "#{SecureRandom.hex(3)}@example.com", name: name)

      assert_match GENERATED, user.username, name.inspect
    end
  end

  # Cut at a word boundary, never mid-word; a single word too long for the
  # maximum makes no seeded name at all.
  def test_a_long_seed_is_cut_at_a_word_boundary
    short = model(seed: :name, length: 3..12)

    assert_equal "pedro", short.create!(name: "Pedro Gonzales Armillon").username
    refute_match(/maxim/, short.create!(name: "Maximilianusz").username, "not maximilian_42, not maximil")
  end

  def test_a_given_name_is_never_replaced_by_the_seed
    user = SeededUser.create!(username: "javi", name: "Ana")

    assert_equal "javi", user.username
    refute_predicate user, :username_generated?
  end

  def test_seed_as_procs
    assert_equal "ana", model(seed: -> { name }).create!(name: "Ana").username
    assert_equal "beto", model(seed: ->(record) { record.name.downcase }).create!(name: "BETO").username
  end

  # An email is used only when the seed returns one, and then as
  # Usernames.generate reads it: the local part without its +tag, or the
  # domain for a generic local part.
  def test_a_seed_that_is_an_email
    seeded = model(seed: :email)

    assert_equal "ana", seeded.create!(email: "ana+news@example.com").username
    assert_equal "acme", seeded.create!(email: "info@acme.com").username
    assert_match GENERATED, User.create!(email: "carla@example.com").username, "without a seed, never an email"
  end

  # Read once per save; a redraw after a lost race starts from the same seed.
  def test_a_redraw_reuses_the_seed
    reads = 0
    racer = model(seed: -> { (reads += 1) && name }) do
      after_validation { |record| User.insert_all([{ username: record.username }]) if record.name == "Ana" }
    end
    user = racer.create!(name: "Ana")

    assert_match(/\Aana_\d{2,3}\z/, user.username)
    assert_predicate user, :username_generated?
    assert_equal 1, reads
  end

  def test_the_seed_is_not_read_when_nothing_is_generated
    reads = 0
    seeded = model(seed: -> { (reads += 1) && name })
    seeded.create!(username: "javi", name: "Ana")
    seeded.create!(name: "Ana").update!(name: "Other")

    assert_equal 1, reads, "only for the blank new record"
  end

  def test_an_error_in_the_seed_is_the_apps
    broken = model(seed: -> { raise ArgumentError, "the app's bug" })

    error = assert_raises(ArgumentError) { broken.create!(email: "a@example.com") }

    assert_equal "the app's bug", error.message
  end

  def test_seed_rejects_anything_else
    error = assert_raises(Usernames::ConfigurationError) { model(seed: "name") }

    assert_match(/seed: must be a method name or a proc \(got "name"\)/, error.message)
  end

  # --- clearable: -------------------------------------------------------------------------------------

  def test_a_name_may_be_cleared_by_default
    user = User.create!(email: "a@example.com")

    assert user.update(username: "  ")
    assert_nil user.reload.username
  end

  def test_clearable_false_refuses_a_saved_name_saved_blank
    user = KeptUser.create!(email: "a@example.com")

    [nil, "", "   "].each do |blank|
      refute user.update(username: blank), blank.inspect
      assert_equal [{ error: :blank }], user.errors.details[:username]
      assert_equal ["Username can't be blank"], user.errors.full_messages
    end
    assert_predicate user.reload.username, :present?
  end

  # The partition: what clearable: false does not touch.
  def test_clearable_false_is_not_immutability
    user = KeptUser.create!(username: "javi", email: "a@example.com")

    assert user.update(username: "ana"), "another name is fine"
    assert user.update(name: "Unrelated")
  end

  def test_clearable_false_leaves_legacy_blanks_alone
    [nil, "", "  "].each do |blank|
      user = legacy(KeptUser, blank)

      assert user.update(name: "Unrelated"), "unrelated, over #{blank.inspect}"
      assert user.update(username: ""), "a stored blank was never a name (#{blank.inspect})"
    end
  end

  def test_clearable_false_on_a_new_record_is_creation
    user = model(clearable: false, generate: false).new(email: "a@example.com", username: "javi")
    user.username = nil

    assert user.save, "assigned then erased before the first save: there is nothing saved to clear"
    assert_nil user.username
  end

  def test_clearable_false_and_a_generated_name
    user = KeptUser.create!(email: "a@example.com")

    refute user.update(username: nil)
    refute_nil user.reload.username, "and never silently replaced by a new one"
  end

  def test_clearable_false_with_required_is_one_error
    user = model(clearable: false, required: true).create!(username: "javi", email: "a@example.com")

    refute user.update(username: "")
    assert_equal [{ error: :blank }], user.errors.details[:username]
  end

  def test_clearable_false_with_required_in_a_context_is_one_error
    user = model(clearable: false, required: { on: :profile }).create!(username: "javi")
    user.username = nil

    refute user.save(context: :profile)
    assert_equal [{ error: :blank }], user.errors.details[:username]
    refute user.save, "outside the context too"
  end

  def test_clearable_false_is_a_validation_so_bypasses_skip_it
    user = KeptUser.create!(username: "javi", email: "a@example.com")
    user.update_column(:username, nil)

    assert_nil user.reload.username
    assert user.update(name: "After"), "the old name is gone: nothing left to protect"
  end

  def test_clearable_must_be_a_boolean
    error = assert_raises(Usernames::ConfigurationError) { model(clearable: :yes) }

    assert_match(/clearable: must be true or false \(got :yes\)/, error.message)
  end
end
