# frozen_string_literal: true

module Usernames
  class Error < StandardError; end

  # A configuration value the gem cannot use, named in the message.
  class ConfigurationError < Error; end

  # Every generated candidate was taken (generate_username draws one batch).
  class NoFreeNameError < Error; end

  # A bundled data file (data/**) is missing or not what the gem expects.
  # Raised when the gem loads: without its word lists the gem would check
  # nothing at all — `admin` registrable, every slur allowed — and say nothing.
  class DataError < Error; end
end
