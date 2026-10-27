# frozen_string_literal: true

module Usernames
  # The answer to `Usernames.check`: whether a name may be registered, and if
  # not, which rule said so.
  #
  #   reason     the error type a model would get (:username_reserved, :too_short…)
  #   rule       for a content verdict, which kind of match it was: :impersonation,
  #              :exact, :route, :custom, :severe, :strong, :hate_number, :adapter.
  #              nil when the name is fine or failed a format rule (the reason
  #              already names a format rule exactly).
  #   canonical  the normalised name the rules were applied to
  #   message    the error message in the current locale, or nil when ok.
  #              Never contains what was typed — and never which word matched.
  #
  # `::Data`, not `Data`: inside this namespace `Data` is Usernames::Data.
  Result = ::Data.define(:ok?, :reason, :rule, :canonical, :message) do
    # `record` and `attribute` word the message the way that model's own
    # error would be worded (see Failure#message).
    def self.for(canonical, failure, record: nil, attribute: nil)
      return new(ok?: true, reason: nil, rule: nil, canonical: canonical, message: nil) unless failure

      new(ok?: false, reason: failure.reason, rule: failure.rule, canonical: canonical,
          message: failure.message(record, attribute))
    end
  end

  # One failed rule, as the pipeline hands it around before it becomes a
  # Result (for the pure functions) or an Active Model error (for the
  # validator). `details` are the interpolations the message needs, kept
  # separate so the validator can hand them to errors.add and let a per-model
  # translation win, exactly as for a Rails error. :nodoc:
  Failure = ::Data.define(:reason, :rule, :details) do
    def initialize(reason:, rule: nil, details: {})
      super
    end

    # A Symbol :message in the details names the translation to use while the
    # type stays `reason` — Active Model's own convention for errors.add.
    #
    # With a `record` (any instance of the model) and its `attribute`, the
    # message is looked up exactly as that model's error would be
    # (activerecord.errors.models.user.attributes.handle.too_short first, then
    # up to errors.messages), so the browser hints and the availability
    # check say what the form says.
    def message(record = nil, attribute = nil)
      return record.errors.generate_message(attribute, reason, details.dup) if record

      I18n.t(details.fetch(:message, reason), scope: %i[errors messages], **details.except(:message)).to_s
    end
  end
end
