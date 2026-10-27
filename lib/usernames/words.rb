# frozen_string_literal: true

module Usernames
  # The generator's default vocabulary, from data/words/: short,
  # everyday, reviewed words that no adjective + animal pair, with any
  # digits, turns into something the gem itself would refuse — the test
  # suite checks every pair. `config.generator.adjectives` / `.nouns` start
  # from these.
  module Words
    ADJECTIVES = Data.adjectives
    ANIMALS = Data.nouns
  end
end
