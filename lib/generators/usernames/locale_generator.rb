# frozen_string_literal: true

require "rails/generators/base"

module Usernames
  module Generators
    # rails generate usernames:locale --locale=fr
    #
    # Copies the gem's English messages to config/locales/usernames.fr.yml,
    # under the `fr:` key, for you to translate. Rails loads an engine's
    # locale files before the app's, so every key you translate wins over
    # the gem's, and every key you leave out still has a message.
    class LocaleGenerator < Rails::Generators::Base
      source_root File.expand_path("../../../config/locales", __dir__)

      desc "Copy the English messages to config/locales/usernames.<locale>.yml for you to translate."

      class_option :locale, type: :string, required: true, desc: "The locale to translate into, like fr or pt-BR"

      # A locale key as I18n spells it: fr, pt-BR, zh-Hant-TW.
      LOCALE = /\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z/

      def copy_locale
        raise Thor::Error, "--locale must be a locale like fr or pt-BR (got #{locale.inspect})" unless LOCALE.match?(locale)

        create_file "config/locales/usernames.#{locale}.yml", translated_copy
      end

      def display_post_install_message
        say "\n\tconfig/locales/usernames.#{locale}.yml is ready to translate.", :green
        say "\nTranslate the values; keep the keys and every placeholder (count, letters, separators_phrase…) " \
            "as it is, and add the plural keys your language needs (one/other are English's). Never add a value " \
            "placeholder: a message must not echo what was typed."
        say "The gem already ships #{locale}; your file overrides it key by key.", :yellow if shipped?
        say "\nThen please consider sending it upstream: https://github.com/rameerez/usernames", :green
      end

      private

      def locale
        options[:locale].to_s
      end

      # The English file with its top-level key swapped, and a note saying so.
      def translated_copy
        english = File.read(File.join(self.class.source_root, "usernames.en.yml"), encoding: "UTF-8")
        note = "# Copied from the usernames gem's English messages by `rails generate usernames:locale --locale=#{locale}`.\n"
        note + english.sub(/^en:$/, "#{locale}:")
      end

      def shipped?
        File.exist?(File.join(self.class.source_root, "usernames.#{locale}.yml"))
      end
    end
  end
end
