# frozen_string_literal: true

module Usernames
  module Adapters
    # `config.offensive.adapters = [:moderate]` (the default): ask the
    # moderate gem's offline wordlist too, when the app has that gem. Without
    # it this is a no-op, not an error — the default must never make an
    # app add a dependency.
    #
    # Moderate reads text, not handles, so the name is handed over the way a
    # person would read it: camelCase split and separators as spaces
    # (`BigBadWolf_x` → "Big Bad Wolf x"), which lets its word-boundary
    # patterns see words.
    module Moderate
      class << self
        def call(name)
          return false unless available?

          ::Moderate::Filters::Wordlist.classify(text_for(name)).flagged?
        end

        def available?
          defined?(::Moderate::Filters::Wordlist) ? true : false
        end

        def text_for(name)
          name.to_s
            .gsub(/([a-z\d])([A-Z])/, '\1 \2')
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1 \2')
            .tr("_.-", "   ")
            .squeeze(" ")
            .strip
        end
      end
    end
  end
end
