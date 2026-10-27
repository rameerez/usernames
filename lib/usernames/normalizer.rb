# frozen_string_literal: true

module Usernames
  # Turns whatever someone typed (or pasted) into the one spelling the gem
  # validates, stores and looks up.
  #
  # The property that matters is IDEMPOTENCE: normalize(normalize(x)) ==
  # normalize(x) for every x. Rails applies `normalizes` on assignment AND in
  # queries, so a value is normalised more than once in its life; a normaliser
  # that changes its own output turns one account into two (Spotify, 2013:
  # `ᴮᴵᴳᴮᴵᴿᴰ` became `BIGBIRD` on the first pass and `bigbird` on the second).
  # The test suite asserts it over the Big List of Naughty Strings and 10,000
  # random Unicode strings, in both case modes.
  #
  # It never raises: a normaliser that raises on a strange byte is a 500 on a
  # sign-up form. And it never strips anything invisible — a zero-width space
  # or a right-to-left override survives, so the character rule refuses it
  # loudly instead of the name silently becoming somebody else's.
  module Normalizer
    # Removed LAST, so nothing after it can expose a second one; and only when
    # a letter or digit follows, so `@` alone (or `@_x`) is left for the
    # character rule to refuse rather than turned into something valid.
    LEADING_AT = {
      lowercase: /\A@(?=[a-z0-9])/,
      preserve: /\A@(?=[A-Za-z0-9])/
    }.freeze

    class << self
      def call(value, case_mode = :lowercase)
        string = utf8(value).unicode_normalize(:nfkc).strip
        # Lowercasing can leave a string that is no longer NFKC (`ǅ` → `ǆ`
        # composes differently), so it is normalised again.
        string = string.downcase.unicode_normalize(:nfkc) if case_mode == :lowercase
        string.sub(LEADING_AT.fetch(case_mode), "")
      end

      # Any value as valid UTF-8. Bytes that cannot be converted are dropped,
      # not guessed at: a name is never built from a byte we could not read.
      def utf8(value)
        string = value.to_s
        string = begin
          string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
        rescue EncodingError # e.g. a dummy encoding, which has no converter
          string.dup.force_encoding(Encoding::UTF_8)
        end
        # Re-encoding UTF-8 into UTF-8 is a no-op that keeps invalid bytes.
        string.scrub("")
      end
    end
  end
end
