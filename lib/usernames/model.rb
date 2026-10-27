# frozen_string_literal: true

module Usernames
  # `has_username`, on every Active Record model (the engine extends
  # ActiveRecord::Base with this module when Active Record loads).
  module Model
    # TODO(p3): PRD §6.1 — normalizes, validation on change, presence when
    # required, uniqueness through Usernames::Comparison, a generated name on
    # create, the race wrapper, and the class helpers.
    def has_username(*, **)
      raise NotImplementedError,
            "has_username is not available in this version yet. Meanwhile: " \
            "`normalizes :username, with: Usernames.normalizer` and `validates :username, username: true`."
    end
  end
end
