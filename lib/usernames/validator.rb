# frozen_string_literal: true

require "active_model"

module ActiveModel
  module Validations
    # validates :username, username: true
    # validates :username, username: { length: 2..15, separators: %w[_ .] }
    # validates :username, username: { message: "isn't available" }
    #
    # The rules only — format, reserved, offensive — with no database: you
    # keep your own uniqueness validation and index (has_username brings both).
    #
    # It validates the value AS SUPPLIED. In lowercase mode `Javi`
    # fails "can only contain lowercase letters…", because `Javi` is not what
    # would be stored: validate what you store. Pair it with
    #
    #   normalizes :username, with: Usernames.normalizer
    #
    # and typed `  @Javi ` becomes `javi` before this ever sees it.
    #
    # One error at most, for the first rule that fails, so a form never shows
    # a stack of complaints about one short string. nil is skipped (presence
    # is a separate question: `validates :username, presence: true`).
    class UsernameValidator < EachValidator
      # Options Active Model itself understands; everything else is a rule.
      VALIDATION_OPTIONS = %i[message strict if unless on allow_nil allow_blank class].freeze

      # Bad rule options fail when the model is defined, not at the first sign-up.
      def check_validity!
        rules
      end

      def validate_each(record, attribute, value)
        return if value.nil?

        failure = rules.failure_for(value)
        return unless failure

        # The details first and `message:` last, so a message passed to the
        # validator replaces every rule's message.
        record.errors.add(attribute, failure.reason, **failure.details, **options.slice(:message, :strict))
      end

      private

      # Resolved on every validation (and cached by the configuration), so a
      # configuration changed after the model was loaded still applies.
      def rules
        Usernames.configuration.rules_for(**options.except(*VALIDATION_OPTIONS))
      end
    end

    module HelperMethods
      # validates_username_of :username, length: 2..15
      def validates_username_of(*attr_names)
        validates_with UsernameValidator, _merge_attributes(attr_names)
      end
    end
  end
end
