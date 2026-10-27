# frozen_string_literal: true

module Usernames
  # Reserved names (PRD §9): the exact list (config.reserved, your routes,
  # the bundled system, mailbox and web words) and the impersonation list
  # (config.forbidden, the bundled impersonation words, your app's name),
  # with config.allowed lifting individual words.
  module Reserved
    # The kind of reservation that matched — :impersonation, :exact, :route
    # or :custom — or nil when the name is free to use. `key` is
    # Usernames.comparison_key of a name that already passed every format
    # rule; `rules` is the Usernames::Rules in force.
    #
    # TODO(p2): the matcher of PRD §9.2 (R0/R1 forms, segments, plurals,
    # `.well-known`/`xn--` prefixes) and route collection (§9.3). Until then
    # nothing is reserved, so the pipeline is complete and every caller
    # already goes through here.
    def self.verdict(_key, _rules)
      nil
    end
  end
end
