# frozen_string_literal: true

require "yaml"

module Usernames
  # The gem's own messages that are not a record's errors — what the
  # availability check says — looked up so they never read
  # "Translation missing":
  #
  # 1. in the current locale, so the app's own translation wins;
  # 2. else in English as I18n has it (the app's English wording, if any);
  # 3. else in the gem's English, read from config/locales/usernames.en.yml
  #    itself — for an app whose available locales leave English out, where
  #    I18n never loads it.
  #
  # The YAML file stays the one place the words are written. :nodoc:
  module Locale
    ENGLISH = File.expand_path("../../config/locales/usernames.en.yml", __dir__)

    class << self
      # Locale.t(:usernames, :availability, :error) # => "couldn't be checked just now"
      def t(*keys, key)
        I18n.t(key, scope: keys, raise: true)
      rescue I18n::MissingTranslationData
        if I18n.backend.exists?(:en, key, scope: keys)
          I18n.backend.translate(:en, key, scope: keys)
        else
          english(*keys, key)
        end
      end

      # The gem's own English for these keys, from the shipped file.
      def english(*keys)
        @english ||= YAML.safe_load(File.read(ENGLISH, encoding: "UTF-8")).fetch("en").freeze
        @english.dig(*keys.map(&:to_s))
      end
    end
  end
end
