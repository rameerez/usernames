# frozen_string_literal: true

module Usernames
  # The word lists that ship in data/, read once per process and frozen.
  #
  # Every list is a plain text file, one entry per line; blank lines and
  # `#` comments (which carry each block's source and reason, see
  # data/NOTICE) are skipped. A file that is not there reads as an empty
  # list, so the gem still loads from a checkout whose data has not been
  # built yet — the configuration then simply starts from nothing.
  #
  # Note the name: inside `module Usernames`, `Data` is this module. Ruby's
  # own value-object class is `::Data`, and the gem always spells it so.
  module Data
    ROOT = File.expand_path("../../data", __dir__)

    # Matched exactly (PRD §9.1): system words, mailboxes, web paths.
    EXACT_FILES = %w[reserved/system.txt reserved/mailboxes.txt reserved/web.txt].freeze

    # Matched the way impersonators type them (PRD §9.2).
    IMPERSONATION_FILES = %w[reserved/impersonation.txt].freeze

    class << self
      # What `config.reserved` starts from.
      def reserved
        @reserved ||= EXACT_FILES.flat_map { |file| list(file) }.uniq.freeze
      end

      # What `config.forbidden` starts from.
      def impersonation
        @impersonation ||= IMPERSONATION_FILES.flat_map { |file| list(file) }.uniq.freeze
      end

      # The generator's vocabulary (PRD §12.1).
      def adjectives
        @adjectives ||= list("words/adjectives.txt")
      end

      # NOTE(p1a): the PRD calls the default nouns ANIMALS; read from
      # data/words/animals.txt until the generator phase settles the file name.
      def nouns
        @nouns ||= list("words/animals.txt")
      end

      # The entries of one data file, relative to data/ (or an absolute path).
      def list(path)
        path = File.expand_path(path, ROOT)
        return [].freeze unless File.file?(path)

        File.foreach(path, chomp: true).filter_map do |line|
          entry = line.sub(/#.*/, "").strip
          entry.freeze unless entry.empty?
        end.freeze
      end
    end
  end
end
