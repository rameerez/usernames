# frozen_string_literal: true

module Usernames
  # Offensive words (PRD §10): bundled terms in severity tiers per language,
  # hate-number rules and optional adapters (`moderate`, any callable).
  module Offensive
    # The kind of match — :severe, :strong, :hate_number or :adapter — or nil
    # when the name is fine. `key` is Usernames.comparison_key of a name that
    # passed every format rule and is not reserved; `rules` is the
    # Usernames::Rules in force (rules.offensive carries severity, languages,
    # allowed and adapters; rules.on_adapter_failure what a raising adapter means).
    #
    # TODO(p2): the algorithm of PRD §10.2 (segments and wholes of R0 and R1,
    # severe a-1/a-2, strong, hate rules, adapters) over data/offensive/.
    # Until then nothing is refused here.
    def self.verdict(_key, _rules)
      nil
    end
  end
end
